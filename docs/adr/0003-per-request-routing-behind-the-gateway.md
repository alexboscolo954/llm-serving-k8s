---
status: accepted   # milestone E; chat only, embed still goes straight to its Service
---

# Chat requests pick a replica per request, behind the Gateway

A Kubernetes Service balances TCP connections, not requests. LiteLLM keeps its connections to a Backend open, so after KEDA added a second chat replica every request still went to the first one (v0.4.0: replica 0 served 9 requests in CI's window, replica 1 none). Chat now goes LiteLLM → an Istio gateway → the Gateway API Inference Extension's Endpoint Picker (llm-d-router v0.11.0), which picks a replica for each request from its queue and KV cache. The routing layer lives in `base`, so every cluster runs it.

## Considered Options

- **Endpoint Picker in front of LiteLLM**: rejected, the Gateway would lose its place as the single auth and Tenant-limit point, and clients would see two entry points.
- **Kill LiteLLM's kept-alive connections**: rejected, it spreads load by luck, not by how busy each replica is, and adds a TCP and TLS handshake to every request.
- **Envoy Gateway, kgateway or agentgateway instead of Istio**: all implement the extension; Istio is the most widely deployed, and here it runs as a gateway only, with no sidecars.
- **Fall back to plain load balancing when the picker is down (FailOpen)**: rejected, a broken picker would look like a working one. FailClose makes chat fail instead, which CI notices.

## Consequences

- One more hop and two more components (istiod, the Envoy gateway) on every cluster. The Benchmarked Gateway overhead predates this hop.
- If the picker is down, chat is down. It runs as one replica; a second would need leader election.
- The prefix-cache scorer is off: CI's load repeats prompts, and that scorer would keep them on the replica that has seen them.
