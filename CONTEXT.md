# LLM Serving

Serving open LLMs on Kubernetes behind a single gateway, on CPU (kind, in CI) and on NVIDIA GPUs.

## Language

### Serving

**Gateway**:
The single entry point clients call; it authenticates and maps a Virtual model to a Backend.
_Avoid_: proxy, router, LiteLLM (that's the implementation)

**Tenant**:
An isolated consumer of the Gateway with its own keys, rate limits, and budget. Implemented as a LiteLLM team; budgets are not enforced yet.
_Avoid_: team (that's the implementation), user, customer, client

**Virtual model**:
The stable model name a client asks for (`chat`, `embed`), independent of which weights or hardware serve it.
_Avoid_: alias, model id

**Backend**:
One model server deployment that serves one set of weights behind the Gateway.
_Avoid_: worker, engine, vLLM pod

**Endpoint Picker**:
Chooses, for each request, which replica of a Backend serves it, from each replica's queue and KV cache. It sits behind the Gateway: an Istio gateway asks it before forwarding a chat request.
_Avoid_: EPP, scheduler, load balancer (a load balancer picks per connection)

**Weights cache**:
A Backend replica's own volume holding its model weights, so a restart or scale-up loads them from disk instead of downloading them.
_Avoid_: model cache, PVC (that's the implementation)

### GPU platform

**Platform layer**:
The cluster-wide GPU and cost components installed once per cluster, below any Overlay.
_Avoid_: infra, addons

**GPU profile**:
How a GPU node advertises its cards: **dedicated** (one Backend per card) or **shared** (one card time-sliced between several Backends).
_Avoid_: sharing mode, node type

**Price sheet**:
The hourly prices (per CPU core, GiB of memory, GPU and GiB of storage) a cost tool charges each Backend for what it holds. On-prem there is no cloud bill, so they stand in for amortized hardware cost.
_Avoid_: pricing, rates, custom pricing (that's OpenCost's name for it)

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
