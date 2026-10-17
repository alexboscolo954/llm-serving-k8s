# Benchmark session: 1× NVIDIA L4, 2026-10-16

Qwen3-8B on vLLM v0.31.0, single-node RKE2 on a GCP `g2-standard-12` (on-demand: spot L4s were out of stock or reclaimed within minutes).
Exact versions, digests and the model revision are in [`setup.md`](setup.md). Each step's chat flags are in `<step>-chat-args.json`, and raw per-run JSON is in each folder.

**Method:** `vllm bench serve`, random prompts of 1024 input / 256 output tokens, 16 prompts per unit of concurrency, 4 warmup requests, 3 repeats with distinct seeds (so repeats don't hit the prefix cache), median reported.
Engine numbers are measured directly against the vLLM Backend. Repeats differed by less than 0.1%.

## FP8 vs BF16

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="fp8-vs-bf16-dark.png">
  <img alt="Output tokens per second and p95 time to first token for FP8 and BF16 at 1, 4 and 16 concurrent requests. FP8 is 56 to 60 percent faster at every level and has lower TTFT." src="fp8-vs-bf16-light.png">
</picture>

| Concurrency | FP8 tok/s | BF16 tok/s | FP8 gain | FP8 TTFT p95 | BF16 TTFT p95 | FP8 ITL p50 | BF16 ITL p50 |
|---|---|---|---|---|---|---|---|
| 1 | 25.5 | 16.2 | +57% | 236 ms | 356 ms | 38.4 ms | 60.7 ms |
| 4 | 90.9 | 56.7 | +60% | 688 ms | 1,050 ms | 40.9 ms | 65.8 ms |
| 16 | 253.0 | 162.2 | +56% | 1,721 ms | 2,498 ms | 50.9 ms | 75.7 ms |
| 64 | 403.3 | did not finish* | n/a | 25,449 ms | n/a | 81.5 ms | n/a |

- **KV cache:** at `--gpu-memory-utilization=0.90`, FP8 leaves room for **64,320 tokens** of KV cache, BF16 for **19,760**. FP8 fits 3.3× more context on the same card.
- **At concurrency 64 both are KV-bound.** FP8 keeps about 50 requests running and queues the rest, which is why its p95 TTFT jumps to 25 s.
- \***BF16 at 64 did not finish in 58 minutes** (FP8 took 11) and was stopped at the VM's time cap. The engine's own log ([`bf16-64/vllm-engine-stats.log`](bf16-64/vllm-engine-stats.log)) shows the KV cache about 96% full, about 16 requests running and 47 waiting, at about 160 tok/s logged generation. That rate is an engine-side figure, not comparable to the client-measured numbers above, and why the run took this long is not established.

## Gateway overhead (FP8, concurrency 16)

| Path | Output tok/s | TTFT mean | TTFT p50 | TTFT p95 | E2E p95 |
|---|---|---|---|---|---|
| Direct to vLLM | 253.0 | 1,002 ms | 732 ms | 1,721 ms | 16,444 ms |
| Through LiteLLM | 252.6 | 1,406 ms | 1,626 ms | 1,733 ms | 16,317 ms |

Throughput and tail latency are unchanged. Mean time to first token is about 400 ms higher through the gateway, while p95 is not. That pattern fits the gateway changing how the first streamed chunk is delivered, rather than adding work, but this session doesn't prove the cause.
Through LiteLLM, output-token counts are recounted from text (±1 per request), so only latency is compared here.

## Time-slicing (FP8, concurrency 16)

| Setup | Output tok/s | TTFT p95 | ITL p50 |
|---|---|---|---|
| Dedicated GPU, memory cap 0.90 | 253.0 | 1,721 ms | 50.9 ms |
| Shared (time-sliced) GPU, cap 0.70, alone | 252.9 | 1,724 ms | 50.9 ms |
| Shared GPU, cap 0.70, embedding Backend under load | 252.8 | 1,734 ms | 50.9 ms |

- **Moving to a time-sliced card with a lower memory cap costs nothing** at this concurrency.
- **No measurable interference** from the embedding neighbour. **Caveat:** the neighbour's load level was not recorded (its logs were lost when it was scaled down), and its load client had half a CPU. So this shows coexistence works; it does not show that time-slicing is free. `bench/session.sh` now saves the neighbour's throughput log.

## Found by running it

The GPU overlay's embedding Backend had never started: Qwen3-Embedding's default 32k context needs 3.5 GiB of KV cache, and its `0.20` memory share of an L4 leaves 2.6 GiB. It now sets `--max-model-len=8192`. Rendering and schema checks could not catch this.
