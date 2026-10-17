"""Turn `vllm bench serve` results (one JSON object per line) into a markdown table.

Runs at the same concurrency are repeats; the table shows their median.
Exits non-zero if any request failed, so CI fails on a broken harness.
"""
import json
import sys
from statistics import median

COLUMNS = [
    ("Req/s", "request_throughput"),
    ("Output tok/s", "output_throughput"),
    ("TTFT p50 (ms)", "median_ttft_ms"),
    ("TTFT p95 (ms)", "p95_ttft_ms"),
    ("ITL p50 (ms)", "median_itl_ms"),
    ("ITL p95 (ms)", "p95_itl_ms"),
    ("E2E p95 (ms)", "p95_e2el_ms"),
]


def by_concurrency(runs):
    failed = sum(r["failed"] for r in runs)
    if failed or not runs:
        raise SystemExit(f"{failed} failed requests in {len(runs)} runs")
    by_conc = {}
    for r in runs:
        by_conc.setdefault(r["max_concurrency"], []).append(r)
    return dict(sorted(by_conc.items()))


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def report(runs):
    by_conc = by_concurrency(runs)
    lines = [
        "| Concurrency | Runs | " + " | ".join(h for h, _ in COLUMNS) + " |",
        "|---" * (len(COLUMNS) + 2) + "|",
    ]
    for conc, rs in by_conc.items():
        cells = [f"{median(r[k] for r in rs):.1f}" for _, k in COLUMNS]
        lines.append(f"| {conc} | {len(rs)} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


if __name__ == "__main__":
    print(report(load(sys.argv[1])))
