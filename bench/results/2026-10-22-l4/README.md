# Benchmark session: 1× NVIDIA L4, 2026-10-22

Second session, same hardware and method as [2026-10-16](../2026-10-16-l4): Qwen3-8B on vLLM v0.31.0, single-node RKE2 on a GCP `g2-standard-12` (on-demand, us-central1-c; L4s were out of stock in us-west1-a/b/c and us-central1-a/b).
This time the cluster ran the whole stack from `make up`: Postgres for the Gateway's keys, NetworkPolicies, and chat routed through the Istio gateway and the Endpoint Picker.
Exact versions, digests and the model revision are in [`setup.md`](setup.md). Each step's chat flags are in `<step>-chat-args.json`, and raw per-run JSON is in each folder.

**Method:** `vllm bench serve`, random prompts of 1024 input / 256 output tokens, 16 prompts per unit of concurrency, 4 warmup requests, 3 repeats with distinct seeds, median reported. Every point here is FP8 at concurrency 16.

## CI's e2e tests on RKE2

[`e2e.txt`](e2e.txt): 8 passed, against the Gateway on this cluster (the embedding tests were left out: the embedding Backend is off until the time-slicing step).

- Chat, streaming, wrong key (401) and unknown model, with every chat request going LiteLLM → Istio gateway → Endpoint Picker → vLLM. The pool fails closed, so these answers only come back if the picker chose the replica. With one GPU there was one replica, so the picker had nothing to choose between.
- Gateway keys in Postgres, and two Tenants: the one over its limit gets 429, the other 200.
- NetworkPolicies under Canal (kind's CI uses kindnet): an unlabelled pod cannot reach the chat Backend, any pod reaches the Gateway.
- Prometheus scrapes the GPU Operator's DCGM exporter: [`dcgm-gpu-util.json`](dcgm-gpu-util.json) is `DCGM_FI_DEV_GPU_UTIL` for `vllm-chat-0`, and [`shared-busy/dcgm-gpu-util.json`](shared-busy/dcgm-gpu-util.json) a 26-minute range of it.

## Gateway overhead, with the Istio hop

| Path | Output tok/s | TTFT mean | TTFT p50 | TTFT p95 | E2E p95 |
|---|---|---|---|---|---|
| Direct to vLLM | 250.2 | 1,047 ms | 764 ms | 1,827 ms | 16,751 ms |
| LiteLLM → Istio gateway → Endpoint Picker → vLLM | 247.6 | 1,564 ms | 1,537 ms | 2,614 ms | 17,237 ms |

The Gateway path adds about 520 ms to mean time to first token and about 790 ms to p95; throughput and end-to-end latency move by 1–3%.
In the first session, LiteLLM alone (no Istio, no picker) added about 400 ms to the mean and nothing to p95. Across two sessions of 3 runs each, that puts the new hop at roughly 100 ms on the mean; this is one comparison, not a measured breakdown per hop.
Through LiteLLM, output-token counts are recounted from text (±1 per request), so throughput through the Gateway is only indicative.

## Time-slicing (FP8, concurrency 16)

| Setup | Output tok/s | TTFT p95 | ITL p50 | E2E p95 |
|---|---|---|---|---|
| Shared (time-sliced) GPU, cap 0.70, alone | 250.2 | 1,822 ms | 50.9 ms | 16,738 ms |
| Same, embedding Backend running but idle | 250.1 | 1,833 ms | 50.9 ms | 16,746 ms |
| Same, embedding Backend under load | **139.6** | 3,652 ms | 112.9 ms | 36,816 ms |

- **A busy neighbour on a time-sliced card costs the chat model 44% of its throughput** (250 → 140 tok/s) and more than doubles the time between tokens. Time-slicing shares the GPU's compute by taking turns; it gives no isolation.
- **The neighbour's load is recorded** ([`shared-busy/embed-requests-per-s.json`](shared-busy/embed-requests-per-s.json), from Prometheus): about 75 embedding requests/s of 256 tokens for most of the run, mean 59/s, dropping to near 0 for about a minute between batches of 20,000. GPU utilisation was 100% in all but two of the one-minute samples.
- **Correction to the first session.** Its load job built 1,000,000 prompts before sending any, and this session showed that job using 1 GiB of its 2 GiB within 90 seconds and failing after about 12 minutes without a single request (the "idle" row above). The first session used the same job, and its "busy" numbers match the idle row here, so its neighbour was very likely never busy. Its "no measurable interference" result does not hold.
- The busy row was rerun by hand after the fix (`bench/run.sh`, same arguments as `bench/session.sh`), with chat still on the shared card at cap 0.70. The load job now sends batches of 20,000 and the session waits for embedding traffic before measuring.

## Found by running it

- The time-slicing neighbour's load never reached it (above). Rendering, schema checks and the first session's numbers could not show it; counting the neighbour's requests did.
- `make bench-up` passed the laptop's IPv6 address to a firewall rule that only takes IPv4; it now asks `ifconfig.me` for IPv4.
