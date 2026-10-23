# Setup, 2026-10-23T21:05:57Z

```
g2-standard-12	us-central1-c	STANDARD
v1.33.13+rke2r2 containerd://2.2.6-k3s1 Ubuntu 24.04.5 LTS 7.0.0-1014-gcp
NVIDIA L4, 595.91.07, 23034 MiB
CUDA Version: 13.2
gpu-operator v26.7.1
docker.io/vllm/vllm-openai@sha256:c1c9f6fd5c109ba7f0546a59f5b2f15fb87f64c77782e90a27b648b42a8e67c3
Qwen/Qwen3-8B b968826d9c46dd6066d109eabc6255188de91218
```

Bench client: vllm bench serve, random dataset, 1024 input / 256 output tokens (ignore_eos),
16 prompts per unit of concurrency, 4 warmup requests, 3 repeats with distinct seeds, median reported.
