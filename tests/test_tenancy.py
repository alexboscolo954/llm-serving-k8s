"""Multi-tenancy e2e against a running Gateway and its database (`make test` port-forwards it).
A Tenant is a LiteLLM team with its own keys and request-per-minute limit, created here
through the admin API. Backends sit behind NetworkPolicies (base/network-policies.yaml)."""
import json
import os
import subprocess
import urllib.error
import urllib.request
import uuid

import pytest

from test_gateway import URL, chat, post

METRICS_KEY = os.environ.get("METRICS_KEY", "sk-local-metrics")


def status(path, body, key):
    try:
        post(path, body, key=key)
        return 200
    except urllib.error.HTTPError as e:
        return e.code


def tenant(rpm):
    team = json.load(post("/team/new", {"team_alias": f"tenant-{uuid.uuid4().hex[:8]}", "rpm_limit": rpm}))
    return json.load(post("/key/generate", {"team_id": team["team_id"]}))["key"]


def test_tenant_over_its_limit_gets_429_and_another_tenant_does_not():
    limited, other = tenant(rpm=1), tenant(rpm=100)
    # 3 requests at 1/min: even split across two minute windows, one window holds 2
    codes = [status("/v1/chat/completions", chat(), limited) for _ in range(3)]
    assert codes[0] == 200 and 429 in codes, codes
    assert status("/v1/chat/completions", chat(), other) == 200


def test_metrics_key_reads_metrics_and_nothing_else():
    req = urllib.request.Request(URL + "/metrics/", headers={"Authorization": f"Bearer {METRICS_KEY}"})
    assert urllib.request.urlopen(req, timeout=30).status == 200
    assert status("/v1/chat/completions", chat(), METRICS_KEY) == 401


def reach(url, direct_access):
    # A throwaway pod in llm: same image and DNS either way, only the label differs.
    labels = "llm-serving/direct-access=true" if direct_access else "app=netpol-probe"
    r = subprocess.run(
        ["kubectl", "-n", "llm", "run", f"netpol-probe-{uuid.uuid4().hex[:6]}", "--rm", "-i", "--quiet",
         "--restart=Never", "--image=litellm/litellm:v1.104.2", f"--labels={labels}", "--command", "--",
         "python3", "-c", f"import urllib.request; urllib.request.urlopen('{url}', timeout=5)"],
        capture_output=True, text=True, timeout=300)
    return r.returncode == 0


@pytest.mark.parametrize("backend", ["vllm-chat", "vllm-embed"])
def test_backends_refuse_pods_other_than_the_gateway(backend):
    url = f"http://{backend}:8000/health"
    assert reach(url, direct_access=True)
    assert not reach(url, direct_access=False)


def test_any_pod_reaches_the_gateway():
    assert reach("http://litellm:4000/health/liveliness", direct_access=False)
