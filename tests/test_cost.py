"""Cost e2e against a running cluster (`make test-observability` port-forwards OpenCost and
Prometheus). OpenCost has no cloud bill on-prem, so every price comes from the price sheet in
platform/opencost-values.yaml; these tests check it is the one applied, not OpenCost's defaults."""
import json
import os
import subprocess
import urllib.parse
import urllib.request

from test_observability import eventually, query

OPENCOST = os.environ.get("OPENCOST_URL", "http://localhost:9003")
GIB = 2 ** 30


def price_sheet():
    out = subprocess.run(["kubectl", "-n", "opencost", "get", "configmap", "custom-pricing-model",
                          "-o", "json"], check=True, capture_output=True, text=True).stdout
    # the chart renders the price sheet's keys straight into the ConfigMap's data
    return {k: float(v) for k, v in json.loads(out)["data"].items() if k in ("CPU", "RAM")}


def backends():
    """This window's allocation per pod in `llm`, Backends (vllm-*) only."""
    q = urllib.parse.urlencode({"window": "10m", "aggregate": "pod", "filter": 'namespace:"llm"'})
    with urllib.request.urlopen(f"{OPENCOST}/allocation?{q}", timeout=30) as r:
        data = json.load(r)["data"][0] or {}
    return {pod: a for pod, a in data.items() if pod.startswith("vllm-")}


def close(cost, expected):
    # OpenCost rounds costs to 5 decimals; OpenCost's default prices are 5-6% off this sheet.
    return abs(cost - expected) <= 1e-5 + 0.01 * expected


def test_node_prices_come_from_the_price_sheet():
    sheet = price_sheet()
    def check():
        cpu = query("node_cpu_hourly_cost")
        ram = query("node_ram_hourly_cost")
        assert cpu and ram, (cpu, ram)
        assert float(cpu[0]["value"][1]) == sheet["CPU"], cpu
        assert abs(float(ram[0]["value"][1]) - sheet["RAM"]) < 1e-9, ram
    eventually(check)


def test_each_backend_costs_its_cpu_and_memory_hours_at_sheet_prices():
    sheet = price_sheet()
    def check():
        pods = backends()
        assert any(p.startswith("vllm-chat-") for p in pods) and any(p.startswith("vllm-embed-") for p in pods), pods.keys()
        for pod, a in pods.items():
            assert a["cpuCoreHours"] > 0 and a["ramByteHours"] > 0, (pod, a)
            assert close(a["cpuCost"], a["cpuCoreHours"] * sheet["CPU"]), (pod, a["cpuCost"], a["cpuCoreHours"])
            assert close(a["ramCost"], a["ramByteHours"] / GIB * sheet["RAM"]), (pod, a["ramCost"], a["ramByteHours"])
            assert a["gpuCost"] == 0, (pod, a["gpuCost"])   # no GPUs on kind
        return {p: round(a["totalCost"], 5) for p, a in pods.items()}
    print("\ncost per Backend, last 10 minutes (USD):", eventually(check))
