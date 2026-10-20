"""Autoscaling e2e (`make test-autoscaling` starts bench/chat-load.yaml and port-forwards
Prometheus). Under load the chat Backend's queue builds, KEDA adds a second replica, and
that replica gets its own weights cache and serves. Tests run in order."""
import json
import subprocess
import time
import urllib.request

from test_gateway import chat
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


def test_new_replica_serves():
    # Straight to the pod: proves it serves, whatever the Service does with the Gateway's connections.
    pf = subprocess.Popen(["kubectl", "-n", "llm", "port-forward", "pod/vllm-chat-1", "8001:8000"],
                          stdout=subprocess.DEVNULL)
    try:
        time.sleep(3)
        req = urllib.request.Request(
            "http://localhost:8001/v1/chat/completions",
            data=json.dumps(chat(model="Qwen/Qwen2.5-0.5B-Instruct")).encode(),
            headers={"Content-Type": "application/json"})
        r = json.load(urllib.request.urlopen(req, timeout=300))
        assert r["choices"][0]["message"]["content"]
    finally:
        pf.terminate()


def test_report_gateway_split():
    # A measurement, not a claim yet: does the Gateway's traffic reach the new replica?
    time.sleep(120)
    r = query('sum by (pod) (increase(vllm:request_success_total{namespace="llm", pod=~"vllm-chat-[0-9]+"}[2m]))')
    print("\nrequests per chat replica, last 2m:", {x["metric"]["pod"]: round(float(x["value"][1])) for x in r})
    assert r
