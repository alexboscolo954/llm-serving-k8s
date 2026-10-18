CLUSTER := llm-serving
NS      := llm
KEY     := sk-local-dev
K8S     := 1.33.0
PYTEST  ?= python3 -m pytest
RUN     ?= $(shell date +%F)-cpu-kind
TF      := terraform -chdir=bench/infra
# L4 stock-outs are common: retry with another zone (us-west1-a, europe-west4-c...).
# Spot can be reclaimed within minutes when L4s are scarce; SPOT=false is on-demand.
ZONE    ?= us-central1-a
SPOT    ?= true
BENCHKC := $(HOME)/k8s_clusters/llm-bench-l4.yaml
KPS     := kube-prometheus-stack
CRDS    := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
VM      = llm-bench-l4 --zone $$($(TF) output -raw zone)
# Gateway on localhost:4000 for the rest of the recipe line.
GATEWAY := kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & PF=$$!; trap "kill $$PF" EXIT; sleep 3;

.PHONY: up observe smoke test test-observability bench down validate bench-up bench-tunnel bench-gpu bench-down

up: ## kind cluster + CPU overlay, waits until the models are served
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config overlays/cpu-kind/kind-config.yaml
	kubectl apply -k overlays/cpu-kind
	kubectl -n $(NS) rollout status deploy/vllm-chat --timeout=15m
	kubectl -n $(NS) rollout status deploy/vllm-embed --timeout=10m
	kubectl -n $(NS) rollout status deploy/litellm --timeout=5m

observe: ## Prometheus + Grafana, then scrape the Backends and the Gateway (after `make up`)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	helm upgrade --install $(KPS) prometheus-community/kube-prometheus-stack --version 92.10.1 \
	  -n monitoring --create-namespace -f platform/kube-prometheus-stack-values.yaml --wait --timeout 10m
	kubectl apply -k observability

smoke: ## chat completion through the LiteLLM gateway
	@$(GATEWAY) \
	curl -sf http://localhost:4000/v1/chat/completions \
	  -H "Authorization: Bearer $(KEY)" -H "Content-Type: application/json" \
	  -d '{"model":"chat","max_tokens":32,"messages":[{"role":"user","content":"Say hello in one sentence."}]}' \
	| python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["model"], "->", r["choices"][0]["message"]["content"])'

test: ## e2e tests against the running gateway
	@$(GATEWAY) $(PYTEST) -v tests/test_gateway.py

test-observability: ## e2e: targets up, every dashboard query returns data, alert rules loaded
	@kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & a=$$!; \
	kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null & b=$$!; \
	kubectl -n monitoring port-forward svc/$(KPS)-grafana 3000:80 >/dev/null & c=$$!; \
	trap "kill $$a $$b $$c" EXIT; sleep 3; \
	GRAFANA_PASSWORD=$$(kubectl -n monitoring get secret $(KPS)-grafana -o jsonpath='{.data.admin-password}' | base64 -d) \
	  $(PYTEST) -v tests/test_observability.py

bench: ## load test through the gateway; results in bench/results/$(RUN)
	bench/run.sh bench/results/$(RUN)

bench-up: ## L4 VM with RKE2 (auto-deletes after max_hours), kubeconfig in $(BENCHKC)
	$(TF) init -input=false >/dev/null
	$(TF) apply -auto-approve -input=false -var ssh_cidr=$$(curl -s https://ifconfig.me)/32 -var zone=$(ZONE) -var region=$(shell echo $(ZONE) | sed 's/-[a-z]$$//') -var spot=$(SPOT)
	until gcloud compute ssh $(VM) --quiet --command 'sudo test -e /etc/rancher/rke2/rke2.yaml' 2>/dev/null; do sleep 15; done
	gcloud compute ssh $(VM) --quiet --command 'sudo cat /etc/rancher/rke2/rke2.yaml' | sed 's/127.0.0.1:6443/127.0.0.1:16443/' > $(BENCHKC)
	$(MAKE) bench-tunnel

bench-tunnel: ## (re)open the SSH tunnel to the VM's Kubernetes API on localhost:16443
	-pkill -f '16443:127.0.0.1:6443'
	gcloud compute ssh $(VM) --quiet -- -f -N -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -L 16443:127.0.0.1:6443
	KUBECONFIG=$(BENCHKC) kubectl get nodes

bench-gpu: ## GPU Benchmark session (STEPS= to run a subset); results in bench/results/<date>-l4
	KUBECONFIG=$(BENCHKC) bench/session.sh bench/results/$(shell date +%F)-l4 $(STEPS)

bench-down: ## delete the VM and its network, then prove nothing is left running
	-pkill -f '16443:127.0.0.1:6443'
	$(TF) destroy -auto-approve -input=false -var ssh_cidr=0.0.0.0/32
	test -z "$$(gcloud compute instances list --format='value(name)')"

down:
	kind delete cluster --name $(CLUSTER)

validate: ## render, schema-check and policy-check everything, no cluster needed
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kubeconform -strict -summary -kubernetes-version $(K8S) - || exit 1; done
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kyverno apply policies/serving.yaml --resource - || exit 1; done
	kyverno apply policies/serving.yaml --resource bench/job.yaml
	kyverno apply policies/serving.yaml --resource policies/violations.yaml 2>&1 | grep -q 'fail: 4,'   # every rule must bite
	kyverno apply policies/serving.yaml --resource bench/embed-load.yaml
	kubectl kustomize observability | kubeconform -strict -summary -kubernetes-version $(K8S) -schema-location default -schema-location '$(CRDS)' -
	d=$$(mktemp -d) && cp observability/vllm-rules.test.yaml $$d/ && \
	  python3 -c 'import sys,yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sys.stdout)' observability/vllm-rules.yaml > $$d/vllm-rules.yaml && \
	  promtool check rules $$d/vllm-rules.yaml && promtool test rules $$d/vllm-rules.test.yaml
	kubeconform -strict -summary platform/time-slicing-config.yaml bench/job.yaml bench/embed-load.yaml
	terraform -chdir=bench/infra fmt -check
	terraform -chdir=bench/infra init -backend=false -input=false >/dev/null && terraform -chdir=bench/infra validate
	$(PYTEST) -q bench
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
	helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	helm repo update nvidia opencost prometheus-community >/dev/null
	helm template gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator -f platform/gpu-operator-values.yaml -f platform/gpu-operator-rke2-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template opencost opencost/opencost --version 2.5.32 -n opencost -f platform/opencost-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template $(KPS) prometheus-community/kube-prometheus-stack --version 92.10.1 -n monitoring -f platform/kube-prometheus-stack-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
