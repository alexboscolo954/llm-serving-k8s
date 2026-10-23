# Benchmark session: autoscaling across two GPU replicas on 1× NVIDIA L4, 2026-10-23 (UTC)

Same cluster as the [Benchmark sessions](../2026-10-22-l4) (single-node RKE2 on a GCP `g2-standard-12`, us-central1-a, on-demand), versions in [`setup.md`](setup.md). About 40 minutes of VM time, ~$0.70.

A second GPU was not available (the 2-GPU quota was denied twice), so both chat replicas share **one L4, time-sliced** ([`platform/time-slicing-config.yaml`](../../../platform/time-slicing-config.yaml): the card is advertised as 4 `nvidia.com/gpu`). This shows the mechanism on GPUs: scale-up on the queue, a GPU replica's cold start, and the Endpoint Picker routing to it. It does **not** show added capacity: the two replicas share one card's compute.

Step `autoscale` in [`bench/session.sh`](../../../bench/session.sh), test [`tests/test_autoscaling.py`](../../../tests/test_autoscaling.py), the same test CI runs on CPU:
- Both replicas run **Qwen3-4B**, FP8, at 0.45 of the card each ([`autoscale-chat-args.json`](autoscale-chat-args.json)). Qwen3-8B does not fit twice: at 0.90 it already uses about 11.4 GiB outside its KV cache. The Gateway's chat model points at Qwen3-4B for this step.
- Each replica runs at most 4 sequences, so the 16-concurrent [`bench/chat-load.yaml`](../../chat-load.yaml) queues, as in CI. Requests are 2 CPU / 12Gi per replica, so two fit the 48 GB VM.
- The ScaledObject is the one in [`autoscaling/`](../../../autoscaling): 4 waiting requests per replica, 1 to 2 replicas.

## Results

[`autoscale.txt`](autoscale.txt): **all 5 tests pass**.

| | Result |
|---|---|
| Queue under load | 12 requests waiting on replica 0 against a target of 4 ([`autoscale-pods.txt`](autoscale-pods.txt)) |
| KEDA scales to two | HPA "New size: 2" about 1.5 minutes after the load started (00:29:07 UTC) |
| Second replica's cold start on the GPU | created 00:29:07, Ready 00:33:02: **3 min 55 s**, including downloading Qwen3-4B into its own new PVC ([`autoscale-timeline.txt`](autoscale-timeline.txt)) |
| Both replicas on one card | `nvidia-smi`: one L4, two `VLLM::EngineCore` processes, 9,644 and 9,622 MiB ([`autoscale-nvidia-smi.txt`](autoscale-nvidia-smi.txt)) |
| Gateway traffic reaches the new replica | Requests finished in the last 5 minutes: replica 0 370, replica 1 25. Replica 0's count includes the load before replica 1 was Ready, so the split is not a routing ratio |
| The new replica serves on its own | A direct request to `vllm-chat-1` answered in 1 s |

Not measured: throughput with two replicas versus one (one card's compute either way), scale-down (10-minute stabilization window; the VM was deleted first), and each replica's KV cache size (engine logs were not saved).
