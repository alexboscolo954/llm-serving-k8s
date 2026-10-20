---
status: accepted   # milestone C; the embed Backend stays a Deployment (small model, not autoscaled)
---

# Autoscaled Backends are StatefulSets with a per-replica weights cache

vLLM is stateless, but each replica needs several GB of model weights on local disk to start in minutes instead of re-downloading them. Autoscaling a Deployment with one shared ReadWriteOnce PVC breaks as soon as a second replica lands on another node, so autoscaled Backends (today: chat) run as StatefulSets whose `volumeClaimTemplates` give every replica its own cache. KEDA scales them on queue depth with a minimum of one replica.

## Considered Options

- **ReadWriteMany volume shared by all replicas**: rejected, it adds a storage system (NFS, Longhorn) to the Platform layer just for a cache.
- **No cache, download on every start**: rejected, cold starts get slower and Hugging Face rate-limits repeated pulls.
- **Scale to zero**: rejected, a GPU cold start (schedule, load weights, warm up) takes minutes, longer than any client will wait.

## Consequences

- Scaling down leaves the replica's PVC behind; it is reused on the next scale-up, which is the point, but the disk is paid for while idle.
- On a single-GPU cluster a second replica has nowhere to go, so GPU autoscaling is Render-only there (see ADR-0001).
