# LLM Serving

Serving open LLMs on Kubernetes behind a single gateway, on CPU (kind, in CI) and on NVIDIA GPUs.

## Language

### Serving

**Gateway**:
The single entry point clients call; it authenticates and maps a Virtual model to a Backend.
_Avoid_: proxy, router, LiteLLM (that's the implementation)

**Tenant**:
An isolated consumer of the Gateway with its own keys, rate limits, and budget.
_Avoid_: team, user, customer, client

**Virtual model**:
The stable model name a client asks for (`chat`, `embed`), independent of which weights or hardware serve it.
_Avoid_: alias, model id

**Backend**:
One model server deployment that serves one set of weights behind the Gateway.
_Avoid_: worker, engine, vLLM pod

### GPU platform

**Platform layer**:
The cluster-wide GPU and cost components installed once per cluster, below any Overlay.
_Avoid_: infra, addons

**GPU profile**:
How a GPU node advertises its cards: **dedicated** (one Backend per card) or **shared** (one card time-sliced between several Backends).
_Avoid_: sharing mode, node type

**Overlay**:
A deployment target (CPU-kind, GPU) built on the shared base.
_Avoid_: environment, flavor

### Evidence

**Proof level**:
How a claim in this repo is backed: **CI-proven**, **Benchmarked**, or **Render-only**.
_Avoid_: tested/untested, verified

**Benchmark session**:
A time-boxed run on rented GPU hardware whose results are committed together with the exact setup that produced them.
_Avoid_: perf test, load test (a load test is the tool, the session is the recorded event)
