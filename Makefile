CLUSTER := llm-serving
NS      := llm
KEY     := sk-local-dev
K8S     := 1.33.0
PYTEST  ?= python3 -m pytest
RUN     ?= $(shell date +%F)-cpu-kind
# Gateway on localhost:4000 for the rest of the recipe line.
GATEWAY := kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & PF=$$!; trap "kill $$PF" EXIT; sleep 3;

.PHONY: up smoke test bench down validate

up: ## kind cluster + CPU overlay, waits until the models are served
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config overlays/cpu-kind/kind-config.yaml
	kubectl apply -k overlays/cpu-kind
	kubectl -n $(NS) rollout status deploy/vllm-chat --timeout=15m
	kubectl -n $(NS) rollout status deploy/vllm-embed --timeout=10m
	kubectl -n $(NS) rollout status deploy/litellm --timeout=5m

smoke: ## chat completion through the LiteLLM gateway
	@$(GATEWAY) \
	curl -sf http://localhost:4000/v1/chat/completions \
	  -H "Authorization: Bearer $(KEY)" -H "Content-Type: application/json" \
	  -d '{"model":"chat","max_tokens":32,"messages":[{"role":"user","content":"Say hello in one sentence."}]}' \
	| python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["model"], "->", r["choices"][0]["message"]["content"])'

test: ## e2e tests against the running gateway
	@$(GATEWAY) $(PYTEST) -v tests

bench: ## load test through the gateway; results in bench/results/$(RUN)
	kubectl -n $(NS) delete job bench --ignore-not-found
	kubectl -n $(NS) apply -f bench/job.yaml
	until [ -n "$$(kubectl -n $(NS) get job bench -o jsonpath='{.status.succeeded}{.status.failed}')" ]; do sleep 5; done
	mkdir -p bench/results/$(RUN)
	kubectl -n $(NS) logs job/bench > bench/results/$(RUN)/bench.log
	test "$$(kubectl -n $(NS) get job bench -o jsonpath='{.status.succeeded}')" = 1 || { tail -30 bench/results/$(RUN)/bench.log; exit 1; }
	sed -n 's/^RESULT //p' bench/results/$(RUN)/bench.log > bench/results/$(RUN)/raw.jsonl
	python3 bench/report.py bench/results/$(RUN)/raw.jsonl | tee bench/results/$(RUN)/results.md

down:
	kind delete cluster --name $(CLUSTER)

validate: ## render, schema-check and policy-check everything, no cluster needed
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kubeconform -strict -summary -kubernetes-version $(K8S) - || exit 1; done
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kyverno apply policies/serving.yaml --resource - || exit 1; done
	kyverno apply policies/serving.yaml --resource bench/job.yaml
	kyverno apply policies/serving.yaml --resource policies/violations.yaml 2>&1 | grep -q 'fail: 4,'   # every rule must bite
	kubeconform -strict -summary platform/time-slicing-config.yaml bench/job.yaml
	$(PYTEST) -q bench
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
	helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null
	helm repo update nvidia opencost >/dev/null
	helm template gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator -f platform/gpu-operator-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template opencost opencost/opencost --version 2.5.32 -n opencost -f platform/opencost-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
