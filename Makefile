CLUSTER := llm-serving
NS      := llm
KEY     := sk-local-dev
POD     ?= vllm-chat-0
ISTIO   := 1.30.5
GWAPI   := v1.5.1
GAIE    := v1.5.0
# llm-d-router: its CRDs here, its Endpoint Picker image in base/chat-routing.yaml
LLMD    := v0.11.0
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

.PHONY: up platform observe cost autoscale smoke test test-observability test-autoscaling logs-chat follow-chat bench down validate bench-up bench-tunnel bench-gpu bench-down

up: ## kind cluster + CNPG + CPU overlay, waits until the models are served
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config overlays/cpu-kind/kind-config.yaml
	$(MAKE) platform
	kubectl apply -k overlays/cpu-kind
	kubectl -n $(NS) wait --for=condition=Programmed gateway/inference-gateway --timeout=5m
	kubectl -n $(NS) rollout status deploy/chat-epp --timeout=5m
	kubectl -n $(NS) wait --for=condition=Ready cluster/litellm-db --timeout=10m
	kubectl -n $(NS) rollout status sts/vllm-chat --timeout=15m
	kubectl -n $(NS) logs vllm-chat-0 | grep -m1 'Disabling Triton'   # Triton-CPU is off (vllm-chat.yaml)
	kubectl -n $(NS) rollout status deploy/vllm-embed --timeout=10m
	kubectl -n $(NS) rollout status deploy/litellm --timeout=5m
	kubectl -n $(NS) wait --for=condition=complete job/litellm-metrics-key --timeout=5m

platform: ## Platform layer every cluster needs: CNPG, Istio (inference gateway only), Gateway API + Inference Extension CRDs
	helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
	helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GWAPI)/standard-install.yaml
	kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$(GAIE)/manifests.yaml
	kubectl apply --server-side -k "github.com/llm-d/llm-d-router/config/crd?ref=$(LLMD)"
	helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 -n cnpg-system --create-namespace --wait --timeout 10m
	helm upgrade --install istio-base istio/base --version $(ISTIO) -n istio-system --create-namespace --wait
	helm upgrade --install istiod istio/istiod --version $(ISTIO) -n istio-system -f platform/istiod-values.yaml --wait --timeout 10m

observe: ## Prometheus + Grafana, then scrape the Backends and the Gateway (after `make up`)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	helm upgrade --install $(KPS) prometheus-community/kube-prometheus-stack --version 92.10.1 \
	  -n monitoring --create-namespace -f platform/kube-prometheus-stack-values.yaml --wait --timeout 10m
	kubectl apply -k observability

cost: ## OpenCost on the price sheet in platform/opencost-values.yaml (after `make observe`)
	helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null
	helm upgrade --install opencost opencost/opencost --version 2.5.33 \
	  -n opencost --create-namespace -f platform/opencost-values.yaml --wait --timeout 10m

autoscale: ## KEDA, then scale the chat Backend on its queue (after `make observe`)
	helm repo add kedacore https://kedacore.github.io/charts >/dev/null
	helm upgrade --install keda kedacore/keda --version 2.21.0 -n keda --create-namespace --wait --timeout 10m
	kubectl apply -k autoscaling

smoke: ## chat completion through the LiteLLM gateway
	@$(GATEWAY) \
	curl -sf http://localhost:4000/v1/chat/completions \
	  -H "Authorization: Bearer $(KEY)" -H "Content-Type: application/json" \
	  -d '{"model":"chat","max_tokens":32,"messages":[{"role":"user","content":"Say hello in one sentence."}]}' \
	| python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["model"], "->", r["choices"][0]["message"]["content"])'

test: ## e2e tests against the running gateway: routing, Tenants, NetworkPolicies
	@$(GATEWAY) $(PYTEST) -v tests/test_gateway.py tests/test_tenancy.py

test-observability: ## e2e: targets up, every dashboard query returns data, alert rules loaded, cost at sheet prices
	@kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & a=$$!; \
	kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null & b=$$!; \
	kubectl -n monitoring port-forward svc/$(KPS)-grafana 3000:80 >/dev/null & c=$$!; \
	kubectl -n opencost port-forward svc/opencost 9003:9003 >/dev/null & d=$$!; \
	trap "kill $$a $$b $$c $$d" EXIT; sleep 3; \
	GRAFANA_PASSWORD=$$(kubectl -n monitoring get secret $(KPS)-grafana -o jsonpath='{.data.admin-password}' | base64 -d) \
	  $(PYTEST) -v -s tests/test_observability.py tests/test_cost.py

test-autoscaling: ## e2e: under load KEDA adds a chat replica with its own weights cache, and the Gateway uses it
	kubectl -n $(NS) scale deploy/vllm-embed --replicas=0   # unused here; two chat replicas need its memory on a 16 GB node
	kubectl -n $(NS) apply -f bench/chat-load.yaml
	@kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & a=$$!; \
	kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 >/dev/null & p=$$!; \
	trap "kill $$a $$p; kubectl -n $(NS) logs job/chat-load --tail=20; kubectl -n $(NS) delete -f bench/chat-load.yaml --ignore-not-found; kubectl -n $(NS) scale deploy/vllm-embed --replicas=1" EXIT; sleep 3; \
	  $(PYTEST) -v -s tests/test_autoscaling.py

logs-chat: ## a chat replica's crash: the previous container's log, /dev/shm, kernel kills (CI failure dumps)
	-kubectl -n $(NS) describe pod $(POD)
	@# The worker dies before the engine logs its first ERROR: keep what came before it.
	-kubectl -n $(NS) logs $(POD) --previous --tail=400 2>/dev/null || kubectl -n $(NS) logs $(POD) --tail=400
	@# /dev/shm is memory-backed and survives container restarts
	-kubectl -n $(NS) exec $(POD) -- sh -c 'df -h /dev/shm; ls -la /dev/shm'
	@# kind shares the runner's kernel: OOM kills and native crashes (SIGILL, SIGSEGV) land here
	-sudo -n dmesg -T | awk 'tolower($$0) ~ /out of memory|oom-kill|killed process|segfault|traps:|invalid opcode|general protection/; END {print NR " kernel log lines read"}'

follow-chat: ## CI: append every vllm-chat-0 container's log to chat-0.log (`--previous` keeps only the last one)
	while :; do kubectl -n $(NS) logs -f --timestamps vllm-chat-0 2>/dev/null; sleep 5; done >> chat-0.log

bench: ## load test through the gateway; results in bench/results/$(RUN)
	bench/run.sh bench/results/$(RUN)

bench-up: ## L4 VM with RKE2 (auto-deletes after max_hours), kubeconfig in $(BENCHKC)
	$(TF) init -input=false >/dev/null
	$(TF) apply -auto-approve -input=false -var ssh_cidr=$$(curl -4 -s https://ifconfig.me)/32 -var zone=$(ZONE) -var region=$(shell echo $(ZONE) | sed 's/-[a-z]$$//') -var spot=$(SPOT)
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
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kubeconform -strict -summary -kubernetes-version $(K8S) -schema-location default -schema-location '$(CRDS)' -skip InferencePool - || exit 1; done   # no InferencePool schema in the catalog yet
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kyverno apply policies/serving.yaml --resource - || exit 1; done
	kyverno apply policies/serving.yaml --resource bench/job.yaml
	kyverno apply policies/serving.yaml --resource policies/violations.yaml 2>&1 | grep -q 'fail: 4,'   # every rule must bite
	kyverno apply policies/serving.yaml --resource bench/embed-load.yaml
	kyverno apply policies/serving.yaml --resource bench/chat-load.yaml
	for d in observability autoscaling; do kubectl kustomize $$d | kubeconform -strict -summary -kubernetes-version $(K8S) -schema-location default -schema-location '$(CRDS)' - || exit 1; done
	d=$$(mktemp -d) && cp observability/vllm-rules.test.yaml $$d/ && \
	  python3 -c 'import sys,yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sys.stdout)' observability/vllm-rules.yaml > $$d/vllm-rules.yaml && \
	  promtool check rules $$d/vllm-rules.yaml && promtool test rules $$d/vllm-rules.test.yaml
	kubeconform -strict -summary platform/time-slicing-config.yaml bench/job.yaml bench/embed-load.yaml bench/chat-load.yaml
	terraform -chdir=bench/infra fmt -check
	terraform -chdir=bench/infra init -backend=false -input=false >/dev/null && terraform -chdir=bench/infra validate
	$(PYTEST) -q bench
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
	helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	helm repo add kedacore https://kedacore.github.io/charts >/dev/null
	helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
	helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
	helm repo update nvidia opencost prometheus-community kedacore cnpg istio >/dev/null
	helm template gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator -f platform/gpu-operator-values.yaml -f platform/gpu-operator-rke2-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template opencost opencost/opencost --version 2.5.33 -n opencost -f platform/opencost-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template $(KPS) prometheus-community/kube-prometheus-stack --version 92.10.1 -n monitoring -f platform/kube-prometheus-stack-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template keda kedacore/keda --version 2.21.0 -n keda \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template cnpg cnpg/cloudnative-pg --version 0.29.1 -n cnpg-system \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template istiod istio/istiod --version $(ISTIO) -n istio-system -f platform/istiod-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	shellcheck bench/*.sh bench/infra/*.sh   # the GPU session script only runs on rented hardware
