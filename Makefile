CLUSTER := llm-serving
NS      := llm
KEY     := sk-local-dev
K8S     := 1.33.0

.PHONY: up smoke down validate

up: ## kind cluster + CPU overlay, waits until the model is served
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config overlays/cpu-kind/kind-config.yaml
	kubectl apply -k overlays/cpu-kind
	kubectl -n $(NS) rollout status deploy/vllm-chat --timeout=15m
	kubectl -n $(NS) rollout status deploy/litellm --timeout=5m

smoke: ## chat completion through the LiteLLM gateway
	@kubectl -n $(NS) port-forward svc/litellm 4000:4000 >/dev/null & PF=$$!; \
	trap "kill $$PF" EXIT; sleep 3; \
	curl -sf http://localhost:4000/v1/chat/completions \
	  -H "Authorization: Bearer $(KEY)" -H "Content-Type: application/json" \
	  -d '{"model":"chat","max_tokens":32,"messages":[{"role":"user","content":"Say hello in one sentence."}]}' \
	| python3 -c 'import sys,json; r=json.load(sys.stdin); print(r["model"], "->", r["choices"][0]["message"]["content"])'

down:
	kind delete cluster --name $(CLUSTER)

validate: ## render + schema-check everything, no cluster needed
	for o in cpu-kind gpu; do kubectl kustomize overlays/$$o | kubeconform -strict -summary -kubernetes-version $(K8S) - || exit 1; done
	kubeconform -strict -summary platform/time-slicing-config.yaml
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
	helm repo add opencost https://opencost.github.io/opencost-helm-chart >/dev/null
	helm repo update nvidia opencost >/dev/null
	helm template gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator -f platform/gpu-operator-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
	helm template opencost opencost/opencost --version 2.5.32 -n opencost -f platform/opencost-values.yaml \
	  | kubeconform -summary -ignore-missing-schemas -kubernetes-version $(K8S) -
