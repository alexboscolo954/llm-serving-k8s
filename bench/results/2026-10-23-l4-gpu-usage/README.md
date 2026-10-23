# Benchmark session: GPU usage per Backend in OpenCost on 1× NVIDIA L4, 2026-10-23 (UTC)

Same cluster as the [Benchmark sessions](../2026-10-22-l4) (single-node RKE2 on a GCP `g2-standard-12`, us-central1-c, on-demand), versions in [`setup.md`](setup.md). About 37 minutes of VM time, ~$0.60.

The [cost session](../2026-10-22-l4-cost) found `gpuUsageAverage` empty for every pod. OpenCost 1.121.3 reads `DCGM_FI_PROF_GR_ENGINE_ACTIVE` by `namespace`, `pod` and `container`, but the DCGM ServiceMonitor did not honour the exporter's labels: Prometheus renamed the Backend's labels to `exported_*` and filled in the exporter's own pod. [`platform/gpu-operator-values.yaml`](../../../platform/gpu-operator-values.yaml) now sets `honorLabels: true`.

Step `gpu-usage` in [`bench/session.sh`](../../../bench/session.sh): chat (Qwen3-8B FP8, [`gpu-usage-chat-args.json`](gpu-usage-chat-args.json)) holds the whole card while [`bench/chat-load.yaml`](../../chat-load.yaml) keeps it busy for 10 minutes, then CI's cost tests ([`tests/test_cost.py`](../../../tests/test_cost.py)) run against the cluster.

## Results

[`gpu-usage.txt`](gpu-usage.txt): **all 3 tests pass**, including `test_gpu_usage_reaches_each_gpu_backend`, which skips on kind.

- [`gpu-usage-dcgm.json`](gpu-usage-dcgm.json): the DCGM sample now carries the Backend's labels, `namespace="llm"`, `pod="vllm-chat-0"`, `container="vllm"`, value 1.00 at the end of the window.
- [`gpu-usage.json`](gpu-usage.json): OpenCost's allocation for `vllm-chat-0` over the last 10 minutes has `gpuUsageAverage` 0.80 (`gpuEfficiency` 0.80) for 0.164 GPU-hours at $2.50.

The 10-minute average (0.80) is lower than the end-of-window sample (1.00) although the load ran the whole window; why is not established. Only one Backend held a GPU, so this does not show usage split between Backends on a time-sliced card.

## Found by running it

- **The first run, earlier the same day, lost its SSH tunnel** to the API during the step's 10-minute wait, so all 3 tests got "connection refused". `bench/session.sh` now reopens the tunnel (`make bench-tunnel`) before each step and before the cost tests.
