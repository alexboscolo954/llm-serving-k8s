#!/bin/sh
# GPU Benchmark session on the single-L4 RKE2 VM from bench/infra.
#   KUBECONFIG=~/k8s_clusters/llm-bench-l4.yaml bench/session.sh <out-dir> [step ...]
# Steps: platform fp8 gateway shared bf16 (default, in that order), plus the
# opt-in bf16-64: BF16 at concurrency 64 did not finish in an hour on one L4,
# and a full session already takes ~4 h of the VM's 5 h cap.
# Results land on the laptop after every step, so a spot preemption only
# loses the step in progress.
set -eu
out=$1; shift
steps=${*:-platform fp8 gateway shared bf16}
vm=llm-bench-l4

# Refuse to touch any cluster but the bench VM.
[ -n "${KUBECONFIG:-}" ] || { echo "set KUBECONFIG explicitly"; exit 1; }
node=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
case $node in $vm|$vm.*) ;; *) echo "not the bench cluster: $node"; exit 1 ;; esac

# Fixed methodology: 1024 in / 256 out, 3 repeats, median reported.
BENCH="TOKENIZER=Qwen/Qwen3-8B INPUT_LEN=1024 OUTPUT_LEN=256 REPEATS=3 PROMPTS_PER_CONCURRENCY=16 WARMUPS=4"
DIRECT="BASE_URL=http://vllm-chat:8000 MODEL_NAME=Qwen/Qwen3-8B"
CHAT_ARGS='["Qwen/Qwen3-8B","--port=8000","--max-model-len=16384"'

chat() {  # chat <extra args json> <gpu profile>: recreate the chat Backend, wait until it serves
  kubectl -n llm patch deploy vllm-chat --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$CHAT_ARGS,$1]},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector/nvidia.com~1device-plugin.config\",\"value\":\"$2\"}]"
  kubectl -n llm rollout status deploy/vllm-chat --timeout=20m
  mkdir -p "$out"
  kubectl -n llm get deploy vllm-chat -o jsonpath='{.spec.template.spec.containers[0].args}' > "$out/$step-chat-args.json"
}

gpus() {  # gpus <n>: wait until the node advertises n nvidia.com/gpu
  until [ "$(kubectl get node $node -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" = "$1" ]; do sleep 10; done
}

for step in $steps; do
  echo "=== $step"
  case $step in
  platform)
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
    kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null; helm repo update nvidia >/dev/null
    kubectl create ns gpu-operator --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f platform/time-slicing-config.yaml
    kubectl label node $node nvidia.com/device-plugin.config=dedicated --overwrite
    # no Prometheus until milestone B, so no ServiceMonitor CRD
    helm upgrade --install gpu-operator nvidia/gpu-operator --version v26.7.1 -n gpu-operator \
      -f platform/gpu-operator-values.yaml -f platform/gpu-operator-rke2-values.yaml \
      --set dcgmExporter.serviceMonitor.enabled=false
    gpus 1
    kubectl create ns llm --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n llm create secret generic litellm-master-key --from-literal=key="sk-$(openssl rand -hex 16)" \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -k overlays/gpu
    kubectl -n llm scale deploy/vllm-embed --replicas=0   # its shared profile only exists in the shared step
    kubectl -n llm rollout status deploy/vllm-chat --timeout=20m
    mkdir -p "$out"
    {
      echo "# Setup, $(date -u +%FT%TZ)"
      echo; echo '```'
      gcloud compute instances list --filter=name=$vm --format='value(machineType.basename(),zone.basename(),scheduling.provisioningModel)'
      kubectl get node $node -o jsonpath='{.status.nodeInfo.kubeletVersion} {.status.nodeInfo.containerRuntimeVersion} {.status.nodeInfo.osImage} {.status.nodeInfo.kernelVersion}{"\n"}'
      kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
      kubectl -n gpu-operator exec ds/nvidia-driver-daemonset -- nvidia-smi | grep -o 'CUDA Version: [0-9.]*'
      echo "gpu-operator v26.7.1"
      kubectl -n llm get pod -l app=vllm-chat -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
      curl -s https://huggingface.co/api/models/Qwen/Qwen3-8B | python3 -c 'import json,sys; print("Qwen/Qwen3-8B", json.load(sys.stdin)["sha"])'
      echo '```'
      echo; echo "Bench client: vllm bench serve, random dataset, 1024 input / 256 output tokens (ignore_eos),"
      echo "16 prompts per unit of concurrency, 4 warmup requests, 3 repeats with distinct seeds, median reported."
    } > "$out/setup.md"
    cat "$out/setup.md"
    ;;
  fp8)
    chat '"--quantization=fp8","--gpu-memory-utilization=0.90"' dedicated
    bench/run.sh "$out/fp8" $BENCH $DIRECT CONCURRENCY="1 4 16 64"
    ;;
  gateway)  # same as fp8 at c=16, but through LiteLLM: compare TTFT and E2E only
    bench/run.sh "$out/gateway" $BENCH MODEL_NAME=chat CONCURRENCY=16
    ;;
  bf16)
    kubectl -n llm scale deploy/vllm-embed --replicas=0   # frees its slice before going back to one whole GPU
    kubectl label node $node nvidia.com/device-plugin.config=dedicated --overwrite
    gpus 1
    chat '"--gpu-memory-utilization=0.90"' dedicated
    bench/run.sh "$out/bf16" $BENCH $DIRECT CONCURRENCY="1 4 16"
    ;;
  bf16-64)  # KV-starved and very slow, so one run; FP8 repeats differed by <0.1%
    bench/run.sh "$out/bf16-64" $BENCH $DIRECT CONCURRENCY=64 REPEATS=1
    ;;
  shared)  # time-slicing cost: chat alone vs chat next to a busy embed Backend, same caps
    kubectl label node $node nvidia.com/device-plugin.config=shared --overwrite
    gpus 4
    chat '"--quantization=fp8","--gpu-memory-utilization=0.70"' shared
    bench/run.sh "$out/shared-alone" $BENCH $DIRECT CONCURRENCY=16
    kubectl -n llm scale deploy/vllm-embed --replicas=1   # only after chat holds its memory
    kubectl -n llm rollout status deploy/vllm-embed --timeout=15m
    kubectl -n llm apply -f bench/embed-load.yaml
    bench/run.sh "$out/shared-busy" $BENCH $DIRECT CONCURRENCY=16
    kubectl -n llm delete -f bench/embed-load.yaml
    # the embed Backend's own throughput is the proof that the neighbour was actually busy
    kubectl -n llm logs deploy/vllm-embed | grep 'Engine 000' > "$out/shared-busy/vllm-embed-stats.log"
    ;;
  esac
done
