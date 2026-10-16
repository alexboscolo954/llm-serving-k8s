"""End-to-end checks against a running Gateway (`make test` port-forwards it)."""
import json
import os
import urllib.error
import urllib.request

import pytest

URL = os.environ.get("GATEWAY_URL", "http://localhost:4000")
KEY = os.environ.get("GATEWAY_KEY", "sk-local-dev")


def post(path, body, key=KEY):
    req = urllib.request.Request(
        URL + path,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    return urllib.request.urlopen(req, timeout=300)


def chat(**extra):
    return {"model": "chat", "max_tokens": 8, "messages": [{"role": "user", "content": "Hi"}]} | extra


def test_chat_completion():
    r = json.load(post("/v1/chat/completions", chat()))
    assert r["choices"][0]["message"]["content"]


def test_chat_streams_tokens():
    lines = [l.decode().strip() for l in post("/v1/chat/completions", chat(stream=True))]
    events = [l for l in lines if l.startswith("data: ")]
    assert len(events) > 2
    assert events[-1] == "data: [DONE]"


def test_embeddings():
    r = json.load(post("/v1/embeddings", {"model": "embed", "input": ["hello", "world"]}))
    assert len(r["data"]) == 2
    assert len(r["data"][0]["embedding"]) > 0


def test_wrong_key_is_rejected():
    with pytest.raises(urllib.error.HTTPError) as e:
        post("/v1/chat/completions", chat(), key="sk-wrong")
    # ponytail: without a database LiteLLM answers 400 "No connected db"; tighten to 401 once Tenants add Postgres
    assert e.value.code in (400, 401)


def test_unknown_virtual_model_is_rejected():
    with pytest.raises(urllib.error.HTTPError) as e:
        post("/v1/chat/completions", chat(model="gpt-4"))
    assert e.value.code == 400
