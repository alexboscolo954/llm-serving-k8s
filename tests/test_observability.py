"""Observability e2e against a running cluster (`make test-observability` port-forwards
the Gateway, Prometheus and Grafana). Traffic runs in the background for the whole module,
so rate() windows always hold fresh samples."""
import base64
import json
import math
import os
import pathlib
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import pytest

from test_gateway import chat, post

PROM = os.environ.get("PROM_URL", "http://localhost:9090")
GRAFANA = os.environ.get("GRAFANA_URL", "http://localhost:3000")
DASHBOARD = pathlib.Path(__file__).parent.parent / "observability/dashboards/llm-serving.json"
RATE_WINDOW = "2m"   # 8 scrapes at the PodMonitors' 15s interval


@pytest.fixture(scope="module", autouse=True)
def traffic():
    stop = threading.Event()

    def loop():
        while not stop.is_set():
            # unknown model: one failure per round, so the Gateway's failed-requests series exists
            for path, body in [("/v1/chat/completions", chat()),
                               ("/v1/embeddings", {"model": "embed", "input": ["hello"]}),
                               ("/v1/chat/completions", chat(model="gpt-4"))]:
                try:
                    post(path, body)
                except OSError:   # HTTPError, timeouts: keep the traffic going, the asserts judge
                    pass

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    yield
    stop.set()
    t.join(timeout=300)


def get(url, auth=None):
    req = urllib.request.Request(url, headers={"Authorization": auth} if auth else {})
    return json.load(urllib.request.urlopen(req, timeout=30))


def query(expr):
    return get(f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": expr}))["data"]["result"]


def finite(result):
    # histogram_quantile over a window without new samples is NaN, which is not data
    return [r for r in result if math.isfinite(float(r["value"][1]))]


def eventually(check, timeout=300):
    deadline = time.time() + timeout
    while True:
        try:
            return check()
        except AssertionError:
            if time.time() > deadline:
                raise
            time.sleep(10)


def test_backends_and_gateway_are_scraped():
    def check():
        targets = get(f"{PROM}/api/v1/targets?state=active")["data"]["activeTargets"]
        want = {"vllm-chat", "vllm-embed", "litellm"}
        up = {w for t in targets for w in want
              if t["scrapePool"].startswith("podMonitor/llm/") and t["health"] == "up"
              and t["labels"]["pod"].startswith(w + "-")}
        assert up == want, up
    eventually(check)


def test_both_backends_serve_requests():
    def check():
        r = query("sum by (model_name) (increase(vllm:request_success_total[5m])) > 0")
        assert len(r) == 2, r
    eventually(check)


def dashboard_queries():
    dash = json.loads(DASHBOARD.read_text())
    return [(p["title"], t["expr"]) for p in dash["panels"] for t in p["targets"]]


@pytest.mark.parametrize("title,expr", dashboard_queries())
def test_dashboard_query_returns_data(title, expr):
    expr = expr.replace("$__rate_interval", RATE_WINDOW).replace("$model", ".+")

    def check():
        assert finite(query(expr)), f"no data for {expr}"
    eventually(check)


def test_alert_rules_are_loaded():
    def check():
        groups = get(f"{PROM}/api/v1/rules?type=alert")["data"]["groups"]
        rules = {r["name"]: r["health"] for g in groups if g["name"] == "vllm" for r in g["rules"]}
        assert rules == {
            "VLLMTimeToFirstTokenHigh": "ok", "VLLMKVCacheNearlyFull": "ok", "VLLMQueueGrowing": "ok",
        }, rules
    eventually(check)


def test_grafana_has_the_dashboard():
    auth = "Basic " + base64.b64encode(f"admin:{os.environ['GRAFANA_PASSWORD']}".encode()).decode()

    def check():
        try:
            d = get(f"{GRAFANA}/api/dashboards/uid/llm-serving", auth)["dashboard"]
        except urllib.error.HTTPError as e:
            raise AssertionError(e)
        assert len(d["panels"]) == len(json.loads(DASHBOARD.read_text())["panels"])
        # the datasource the panels name exists, or Grafana shows "datasource not found"
        assert get(f"{GRAFANA}/api/datasources/uid/prometheus", auth)["type"] == "prometheus"
    eventually(check)
