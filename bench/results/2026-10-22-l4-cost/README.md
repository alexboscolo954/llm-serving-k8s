# Benchmark session: cost per Backend on 1× NVIDIA L4, 2026-10-22

OpenCost 1.121.3 (chart 2.5.33) on the price sheet in [`platform/opencost-values.yaml`](../../../platform/opencost-values.yaml): $0.03 per core-hour, $0.004 per GiB-hour, $2.50 per GPU-hour.
Same cluster as the [Benchmark sessions](../2026-10-22-l4) (single-node RKE2 on a GCP `g2-standard-12`, us-central1-a), versions in [`setup.md`](setup.md).
Each step holds the Backends idle for 10 minutes, then runs CI's cost tests ([`tests/test_cost.py`](../../../tests/test_cost.py)) against the cluster and saves OpenCost's allocation per pod for the last 10 minutes (`<step>.json`). OpenCost charges a pod for what it holds (its requests, or its usage if higher), so load does not change the GPU result. GPU utilisation per pod is not wired into OpenCost (`gpuUsageAverage` is empty in every allocation; fixed in [2026-10-23-l4-gpu-usage](../2026-10-23-l4-gpu-usage)).

## Dedicated GPU: chat holds the whole card

[`cost-dedicated.txt`](cost-dedicated.txt): both tests pass. `vllm-chat-0` was charged its core-hours at $0.03, its GiB-hours at $0.004, and 0.117 GPU-hours at $2.50 ($0.29 of its $0.32 for the window).

## Time-sliced GPU: each Backend is charged a whole card

| Pod | GPU-hours in the window | GPU cost | OpenCost's `isGPUShared` |
|---|---|---|---|
| `vllm-chat-0` | 0.100 | $0.250 | false |
| `vllm-embed-…` | 0.083 | $0.208 | false |

[`cost-shared.json`](cost-shared.json): chat and embed each hold one of the four time-sliced replicas of the same L4, and OpenCost charges each of them a full GPU at $2.50 an hour. One card costs $5.00 an hour with two Backends on it; by the same rule, four would be charged $10.00. The device plugin advertises time-sliced replicas as whole `nvidia.com/gpu` units, and OpenCost marked neither pod as shared. Whether another OpenCost setting splits them was not tested.
The cost tests still pass here: each pod's GPU cost is its GPU-hours at the sheet's price. They check that the sheet is applied, not that a shared card is split.
Each 10-minute window held 5–7 minutes of data, also in the dedicated run without a restart; why is not established, and rates per hour are unaffected.

## Found by running it

- **OpenCost ignored the price sheet's `provider: custom` on a GCE VM.** It logged "Found ProviderID starting with gce, using GCP Provider", could not reach GCP's pricing API, fell back to the sheet's prices, and then charged CPU and RAM at 70% of them ($0.021 per core-hour, $0.0028 per GiB-hour; the GPU stayed at $2.50). That is 30% off, which matches GCP's sustained-use discount, though OpenCost did not log a discount. The first dedicated run failed CI's test on it ([`discounted/cost-dedicated.txt`](discounted/cost-dedicated.txt)). On kind the node's provider is `kind://`, so CI could not see this.
  OpenCost now runs with `USE_CUSTOM_PROVIDER=true`, which skips the cloud detection; after the fix the same cluster was charged the sheet's prices (the passing runs above).
