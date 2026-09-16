#!/usr/bin/env python3
"""Plot GAPBS config comparisons from the compare CSVs.

Reads gapbs.*.csv in RESULTS_DIR and writes PNG charts under OUT_DIR:

  runtime_<input>_t<n>.png              mean Average Time per kernel
  speedup_<input>_t<n>.png              mean speedup vs --baseline
  geomean_speedup.png                   geomean speedup across kernels
  runtime_<kernel>_<input>_by_threads.png
                                        one cluster per thread count (when
                                        multiple thread counts are present)
"""
from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

CONFIG_LABELS = {
    "clang-plain": "baseline",
    "clang-plainje": "chonk no analysis",
    "clang-chonk": "chonk",
    "clang-plainje-q4": "chonk-q4",
}
CONFIG_ORDER = ["clang-plain", "clang-plainje", "clang-plainje-q4", "clang-chonk"]
CONFIG_COLORS = {
    "clang-plain": "#4C72B0",
    "clang-plainje": "#55A868",
    "clang-plainje-q4": "#C44E52",
    "clang-chonk": "#8172B2",
}
TAG_TO_CONFIG = {
    "plain": "clang-plain",
    "plainje": "clang-plainje",
    "chonk": "clang-chonk",
    "q4": "clang-plainje-q4",
}


def parse_average_from_log(text: str) -> float | None:
    matches = re.findall(r"^Average Time:\s+([\d.]+)", text, re.M)
    if not matches:
        return None
    return float(matches[-1])


def load_rows(results_dir: Path) -> list[dict]:
    rows: list[dict] = []
    for path in sorted(results_dir.glob("gapbs.*.csv")):
        with path.open(newline="") as f:
            for row in csv.DictReader(f):
                if row.get("status") and row["status"] != "ok":
                    continue
                try:
                    row["time_s"] = float(row["time_s"])
                    row["threads"] = int(row["threads"])
                except (KeyError, TypeError, ValueError):
                    continue
                rows.append(row)
    return rows


def load_machine_logs(
    results_dir: Path,
    machine: str,
    kernels: list[str] | None = None,
) -> list[dict]:
    """Load timed runs from <kernel>/<machine>/*.r*.txt logs."""
    rows: list[dict] = []
    app_dirs = (
        [results_dir / a for a in kernels]
        if kernels
        else [p for p in results_dir.iterdir() if p.is_dir()]
    )
    for app_dir in app_dirs:
        log_dir = app_dir / machine
        if not log_dir.is_dir():
            continue
        kernel = app_dir.name
        for path in sorted(log_dir.glob(f"{kernel}.*.t*.*.r*.txt")):
            parts = path.name.split(".")
            # <kernel>.<input>.t<N>.<tag>.r<N>.txt
            if len(parts) < 5 or not parts[2].startswith("t"):
                continue
            tag = parts[3]
            if tag not in TAG_TO_CONFIG:
                continue
            try:
                threads = int(parts[2][1:])
            except ValueError:
                continue
            text = path.read_text(errors="replace")
            if re.search(
                r"Segmentation fault|Aborted|core dumped",
                text,
                re.I,
            ):
                continue
            secs = parse_average_from_log(text)
            if secs is None:
                continue
            rows.append(
                {
                    "config": TAG_TO_CONFIG[tag],
                    "app": kernel,
                    "input": parts[1],
                    "threads": threads,
                    "time_s": secs,
                    "status": "ok",
                    "machine": machine,
                }
            )
    return rows


def grouped(rows: list[dict]) -> dict[tuple[str, int], dict[str, dict[str, list[float]]]]:
    """(input, threads) -> kernel -> config -> [times]."""
    out: dict[tuple[str, int], dict[str, dict[str, list[float]]]] = defaultdict(
        lambda: defaultdict(lambda: defaultdict(list))
    )
    for r in rows:
        out[(r["input"], r["threads"])][r["app"]][r["config"]].append(r["time_s"])
    return out


def mean_std(xs: list[float]) -> tuple[float, float]:
    arr = np.asarray(xs, dtype=float)
    if arr.size == 0:
        return float("nan"), float("nan")
    if arr.size == 1:
        return float(arr[0]), 0.0
    return float(arr.mean()), float(arr.std(ddof=1))


def configs_present(app_data: dict[str, dict[str, list[float]]]) -> list[str]:
    seen: set[str] = set()
    for cfg_times in app_data.values():
        seen.update(cfg_times)
    return [c for c in CONFIG_ORDER if c in seen]


def label(cfg: str) -> str:
    return CONFIG_LABELS.get(cfg, cfg)


def plot_runtime(input_name: str, threads: int, app_data: dict, out: Path) -> None:
    apps = sorted(app_data)
    configs = configs_present(app_data)
    if not apps or not configs:
        return

    x = np.arange(len(apps))
    width = min(0.8 / len(configs), 0.22)
    fig, ax = plt.subplots(figsize=(max(8, 1.15 * len(apps)), 5.2))
    offset0 = -(len(configs) - 1) / 2 * width

    for i, cfg in enumerate(configs):
        means, stds = [], []
        for app in apps:
            m, s = mean_std(app_data[app].get(cfg, []))
            means.append(m)
            stds.append(s)
        ax.bar(
            x + offset0 + i * width,
            means,
            width,
            yerr=stds,
            capsize=2.5,
            label=label(cfg),
            color=CONFIG_COLORS.get(cfg),
            error_kw={"elinewidth": 0.8},
        )

    ax.set_xticks(x, apps, rotation=20, ha="right")
    ax.set_ylabel("Average Time (s)")
    ax.set_xlabel("Kernel")
    ax.set_title(f"GAPBS mean Average Time · {input_name} · {threads} threads")
    ax.legend(title="Config")
    ax.set_axisbelow(True)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.6)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_speedup(
    input_name: str, threads: int, app_data: dict, baseline: str, out: Path
) -> None:
    apps = sorted(app_data)
    configs = [c for c in configs_present(app_data) if c != baseline]
    if not apps or not configs:
        return

    x = np.arange(len(apps))
    width = min(0.8 / len(configs), 0.22)
    fig, ax = plt.subplots(figsize=(max(8, 1.15 * len(apps)), 5.2))
    offset0 = -(len(configs) - 1) / 2 * width

    for i, cfg in enumerate(configs):
        speeds = []
        for app in apps:
            base_m, _ = mean_std(app_data[app].get(baseline, []))
            cfg_m, _ = mean_std(app_data[app].get(cfg, []))
            if base_m > 0 and not math.isnan(cfg_m):
                speeds.append(base_m / cfg_m)
            else:
                speeds.append(float("nan"))
        ax.bar(
            x + offset0 + i * width,
            speeds,
            width,
            label=label(cfg),
            color=CONFIG_COLORS.get(cfg),
        )

    ax.axhline(1.0, color="0.35", linewidth=0.8, linestyle="--")
    ax.set_xticks(x, apps, rotation=20, ha="right")
    ax.set_ylabel(f"Speedup vs {label(baseline)} (higher is better)")
    ax.set_xlabel("Kernel")
    ax.set_title(f"GAPBS speedup vs {label(baseline)} · {input_name} · {threads} threads")
    ax.legend(title="Config")
    ax.set_axisbelow(True)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.6)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def geomean(xs: list[float]) -> float:
    vals = [x for x in xs if x > 0 and not math.isnan(x)]
    if not vals:
        return float("nan")
    return float(math.exp(sum(math.log(x) for x in vals) / len(vals)))


def plot_app_by_threads(
    rows: list[dict],
    app: str,
    input_name: str,
    configs: list[str],
    thread_counts: list[int] | None,
    out: Path,
    machine: str | None = None,
) -> bool:
    """Clustered bars: one cluster per thread count, one bar per config."""
    times: dict[tuple[int, str], list[float]] = defaultdict(list)
    for r in rows:
        if r["app"] != app or r["input"] != input_name:
            continue
        if r["config"] not in configs:
            continue
        if thread_counts is not None and r["threads"] not in thread_counts:
            continue
        times[(r["threads"], r["config"])].append(r["time_s"])
    if not times:
        return False

    counts = thread_counts or sorted({t for t, _ in times})
    configs = [c for c in configs if any((n, c) in times for n in counts)]
    if not counts or not configs or len(counts) < 2:
        return False

    x = np.arange(len(counts))
    width = min(0.8 / len(configs), 0.24)
    offset0 = -(len(configs) - 1) / 2 * width
    fig, ax = plt.subplots(figsize=(8.5, 5.2))

    for i, cfg in enumerate(configs):
        means, stds = [], []
        for n in counts:
            m, s = mean_std(times.get((n, cfg), []))
            means.append(m)
            stds.append(s)
        ax.bar(
            x + offset0 + i * width,
            means,
            width,
            yerr=stds,
            capsize=2.5,
            label=label(cfg),
            color=CONFIG_COLORS.get(cfg),
            error_kw={"elinewidth": 0.8},
        )

    ax.set_xticks(x, [str(n) for n in counts])
    ax.set_xlabel("Threads")
    ax.set_ylabel("Average Time (s)")
    title = f"GAPBS mean Average Time · {app} · {input_name}"
    if machine:
        title += f" · {machine}"
    ax.set_title(title)
    ax.legend(title="Config")
    ax.set_axisbehind(True)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.6)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return True


def plot_geomean(data, baseline: str, out: Path) -> None:
    combos = sorted(data, key=lambda k: (k[0], k[1]))
    configs: list[str] = []
    for combo in combos:
        for c in configs_present(data[combo]):
            if c != baseline and c not in configs:
                configs.append(c)
    configs = [c for c in CONFIG_ORDER if c in configs]
    if not combos or not configs:
        return

    labels = [f"{inp}\nt{n}" for inp, n in combos]
    x = np.arange(len(combos))
    width = min(0.8 / len(configs), 0.22)
    fig, ax = plt.subplots(figsize=(max(8, 1.1 * len(combos)), 5.0))
    offset0 = -(len(configs) - 1) / 2 * width

    for i, cfg in enumerate(configs):
        geos = []
        for combo in combos:
            app_data = data[combo]
            speeds = []
            for app, cfg_times in app_data.items():
                base_m, _ = mean_std(cfg_times.get(baseline, []))
                cfg_m, _ = mean_std(cfg_times.get(cfg, []))
                if base_m > 0 and not math.isnan(cfg_m):
                    speeds.append(base_m / cfg_m)
            geos.append(geomean(speeds))
        ax.bar(
            x + offset0 + i * width,
            geos,
            width,
            label=label(cfg),
            color=CONFIG_COLORS.get(cfg),
        )

    ax.axhline(1.0, color="0.35", linewidth=0.8, linestyle="--")
    ax.set_xticks(x, labels)
    ax.set_ylabel(f"Geomean speedup vs {label(baseline)}")
    ax.set_xlabel("Graph · threads")
    ax.set_title(f"GAPBS geomean speedup vs {label(baseline)}")
    ax.legend(title="Config")
    ax.set_axisbelow(True)
    ax.yaxis.grid(True, linestyle=":", linewidth=0.6)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--results-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Directory with gapbs.*.csv files (default: this script's directory)",
    )
    p.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="Where to write PNGs (default: <results-dir>/graphs-out)",
    )
    p.add_argument(
        "--baseline",
        default="clang-plain",
        help="Config used as 1.0x in speedup plots (default: clang-plain)",
    )
    p.add_argument("--input", help="Only plot this graph (e.g. kron22)")
    p.add_argument("--threads", type=int, help="Only plot this thread count")
    p.add_argument(
        "--machine",
        default="h0",
        help="Machine subdirectory under <kernel>/ for by-threads log plots",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    results_dir = args.results_dir.resolve()
    # PNGs go to graphs-out so they are not mixed with serialized .sg inputs.
    out_dir = (args.out_dir or results_dir / "graphs-out").resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = load_rows(results_dir)
    if not rows:
        print(f"No usable rows in {results_dir}/gapbs.*.csv", file=sys.stderr)
        return 1

    data = grouped(rows)
    written: list[Path] = []
    for (input_name, threads), app_data in sorted(
        data.items(), key=lambda kv: (kv[0][0], kv[0][1])
    ):
        if args.input and input_name != args.input:
            continue
        if args.threads is not None and threads != args.threads:
            continue
        rt = out_dir / f"runtime_{input_name}_t{threads}.png"
        sp = out_dir / f"speedup_{input_name}_t{threads}.png"
        plot_runtime(input_name, threads, app_data, rt)
        plot_speedup(input_name, threads, app_data, args.baseline, sp)
        written.extend([rt, sp])

    if args.threads is None:
        kernels = sorted({r["app"] for r in rows})
        inputs = sorted({r["input"] for r in rows})
        for kernel in kernels:
            for input_name in inputs:
                if args.input not in (None, input_name):
                    continue
                out = out_dir / f"runtime_{kernel}_{input_name}_by_threads.png"
                if plot_app_by_threads(
                    rows,
                    app=kernel,
                    input_name=input_name,
                    configs=["clang-plain", "clang-plainje", "clang-chonk"],
                    thread_counts=None,
                    out=out,
                ):
                    written.append(out)

    geo = out_dir / "geomean_speedup.png"
    plot_geomean(data, args.baseline, geo)
    written.append(geo)

    print(f"Wrote {len(written)} charts to {out_dir}")
    for p in written:
        print(f"  {p.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
