"""Autoscaling e2e (`make test-autoscaling` starts bench/chat-load.yaml and port-forwards the
Gateway and Prometheus). Under load the chat Backend's queue builds, KEDA adds a second replica, and
that replica gets its own weights cache, receives Gateway traffic through the Endpoint
Picker once the load stops, and answers on its own. Tests run in order."""
import json
import socket
import subprocess
import time
import urllib.request

from test_gateway import chat, post
from test_observability import eventually, query

WAITING = 'sum(vllm:num_requests_waiting{namespace="llm", pod=~"vllm-chat-[0-9]+"})'


def kubectl(*args):
    return subprocess.run(["kubectl", "-n", "llm", *args], check=True, capture_output=True, text=True).stdout


def sts(field):
    return kubectl("get", "sts", "vllm-chat", "-o", f"jsonpath={{.{field}}}")


def test_queue_builds_under_load():
    def check():
        r = query(WAITING)
        assert r and float(r[0]["value"][1]) > 0, r
    eventually(check)


def test_keda_scales_to_two():
    def check():
        assert sts("spec.replicas") == "2"
    eventually(check)


def test_new_replica_ready_with_its_own_cache():
    def check():   # weights download + CPU warmup next to a saturated replica 0
        assert sts("status.readyReplicas") == "2"
    eventually(check, timeout=1500)
    phases = kubectl("get", "pvc", "hf-cache-vllm-chat-0", "hf-cache-vllm-chat-1",
                     "-o", "jsonpath={.items[*].status.phase}")
    assert phases == "Bound Bound"


def test_gateway_sends_traffic_to_the_new_replica():
    # Load off first: two CPU replicas under full load stalled the whole 4-vCPU CI node. Then short
    # requests through the Gateway, before the direct request below, so only Gateway traffic counts.
    # Through a Service, LiteLLM's kept-alive connections all stayed on replica 0 (v0.4.0); the
    # Endpoint Picker chooses a replica per request.
    kubectl("delete", "job", "chat-load", "--cascade=foreground", "--wait")
    for _ in range(10):
        post("/v1/chat/completions", chat())
    split = 'sum by (pod) (increase(vllm:request_success_total{namespace="llm", pod=~"vllm-chat-[0-9]+"}[5m]))'
    def check():
        r = {x["metric"]["pod"]: round(float(x["value"][1])) for x in query(split)}
        assert r.get("vllm-chat-1", 0) > 0, r
        return r
    print("\nrequests finished per chat replica, last 5m:", eventually(check, timeout=180))


def test_new_replica_serves():
    # Straight to the pod: it answers on its own, not only as a target of the Gateway.
    pf = subprocess.Popen(["kubectl", "-n", "llm", "port-forward", "pod/vllm-chat-1", "8001:8000"],
                          stdout=subprocess.DEVNULL)
    try:
        for _ in range(60):   # kubectl is slow to listen on a runner saturated by two CPU replicas
            try:
                socket.create_connection(("localhost", 8001), timeout=1).close()
                break
            except OSError:
                time.sleep(1)
        req = urllib.request.Request(
            "http://localhost:8001/v1/chat/completions",
            data=json.dumps(chat(model="Qwen/Qwen2.5-0.5B-Instruct")).encode(),
            headers={"Content-Type": "application/json"})
        # Replica 0 keeps all 4 vCPUs busy, so one short request here took 4-5 minutes in CI.
        start = time.time()
        r = json.load(urllib.request.urlopen(req, timeout=900))
        print(f"\nreplica 1 answered in {time.time() - start:.0f}s")
        assert r["choices"][0]["message"]["content"]
    finally:
        pf.terminate()
