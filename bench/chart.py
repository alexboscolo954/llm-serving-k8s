"""Throughput and p95 TTFT against concurrency, one line per configuration.

    python3 bench/chart.py <out-prefix> FP8=<dir>/raw.jsonl BF16=<dir>/raw.jsonl

Writes <out-prefix>-light.png and <out-prefix>-dark.png (for GitHub's
prefers-color-scheme). Two panels share the x axis; there is no second y axis.
"""
import sys
from statistics import median

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import StrMethodFormatter

from report import by_concurrency, load

# Validated with the dataviz palette checker (2 series, light and dark surfaces).
THEMES = {
    "light": {"surface": "#fcfcfb", "text": "#0b0b0b", "muted": "#52514e", "grid": "#e4e3dd",
              "series": ["#2a78d6", "#eb6834"]},
    "dark": {"surface": "#1a1a19", "text": "#ffffff", "muted": "#c3c2b7", "grid": "#383835",
             "series": ["#3987e5", "#d95926"]},
}
PANELS = [("output_throughput", "Output tokens/s (higher is better)"),
          ("p95_ttft_ms", "Time to first token p95, ms (lower is better)")]


def draw(series, theme, path):
    t = THEMES[theme]
    fig, axes = plt.subplots(1, 2, figsize=(10, 3.8), facecolor=t["surface"])
    for ax, (key, title) in zip(axes, PANELS):
        ax.set_facecolor(t["surface"])
        for (label, by_conc), color in zip(series, t["series"]):
            xs = list(by_conc)
            ys = [median(r[key] for r in rs) for rs in by_conc.values()]
            ax.plot(xs, ys, color=color, linewidth=2, marker="o", markersize=8,
                    markeredgecolor=t["surface"], markeredgewidth=2, label=label)
            ax.annotate(f"{label} {ys[-1]:,.0f}", (xs[-1], ys[-1]), xytext=(6, 0),
                        textcoords="offset points", va="center", color=t["text"], fontsize=9)
        ax.set_xscale("log", base=2)
        ax.set_xticks(xs, [str(x) for x in xs])
        ax.set_xlabel("Concurrent requests", color=t["muted"])
        ax.set_title(title, color=t["text"], fontsize=11, loc="left")
        ax.grid(axis="y", color=t["grid"], linewidth=1)
        ax.tick_params(colors=t["muted"], length=0)
        for side in ("top", "right", "left"):
            ax.spines[side].set_visible(False)
        ax.spines["bottom"].set_color(t["grid"])
        ax.set_ylim(bottom=0)
        ax.yaxis.set_major_formatter(StrMethodFormatter("{x:,.0f}"))
        ax.margins(x=0.18)
    axes[0].legend(frameon=False, labelcolor=t["text"], loc="upper left")
    fig.tight_layout()
    fig.savefig(path, dpi=150, facecolor=t["surface"])


if __name__ == "__main__":
    prefix, *pairs = sys.argv[1:]
    series = [(label, by_concurrency(load(path))) for label, path in (p.split("=", 1) for p in pairs)]
    for theme in THEMES:
        draw(series, theme, f"{prefix}-{theme}.png")
