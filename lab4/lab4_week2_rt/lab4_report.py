#!/usr/bin/env python3
"""lab4_report.py - turn Lab 4 results into REPORT.md + Excel-ready CSVs.

Usage:
    python3 lab4_report.py results                 # on the Pi or your laptop
    python3 lab4_report.py results --archive DIR   # also list old logs (labelled "archived")
    python3 lab4_report.py results --with ../lab4_week1_stock/results   # merge week-1 data in

If --with is not given, ../lab4_week1_stock/results and ../lab4_week2_rt/results
are merged automatically when they exist next to this folder.

Reads results/ALL_RUNS.csv, results/ALL_WAVES.csv and the newest full
stock_*/ rt_* run folders. Writes:
    results/REPORT.md          stock vs RT tables + what is still missing
    results/hist_compare.csv   latency_us vs count (sum of 4 threads) per kernel/condition
    results/hist_compare.png   same, log scale (only if matplotlib is installed)
Standard library only (matplotlib optional).
"""
import csv, glob, os, re, sys
from collections import defaultdict

args = sys.argv[1:]
if not args or args[0] in ("-h", "--help"):
    print(__doc__); sys.exit(0)
RES = args[0]
ARCH = args[args.index("--archive") + 1] if "--archive" in args else None
DIRS = [RES] + [args[i + 1] for i, a in enumerate(args) if a == "--with"]
if "--with" not in args:
    here = os.path.dirname(os.path.abspath(RES))
    for sib in ("lab4_week1_stock", "lab4_week2_rt"):
        d = os.path.join(os.path.dirname(here), sib, "results")
        if os.path.isdir(d) and os.path.abspath(d) != os.path.abspath(RES):
            DIRS.append(d)


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def fmt(x, nd=0):
    if x is None:
        return "–"
    return f"{x:,.{nd}f}"


runs = [r for d in DIRS for r in read_csv(os.path.join(d, "ALL_RUNS.csv"))]
waves = [r for d in DIRS for r in read_csv(os.path.join(d, "ALL_WAVES.csv"))]
out = []
w = out.append

w("# Lab 4 results: stock vs PREEMPT_RT\n")
w("Generated from: " + ", ".join(f"`{os.path.abspath(d)}`" for d in DIRS) + ". Quick (`--quick`) runs are excluded.\n")

# ----------------------------------------------------------------- uname ---
for f in sorted(g for d in DIRS for g in glob.glob(os.path.join(d, "uname_week*_*.txt"))):
    with open(f) as fh:
        lines = fh.read().splitlines()
    un = next((lines[i + 1] for i, l in enumerate(lines) if l.startswith("$ uname -a") and i + 1 < len(lines)), "")
    w(f"- `{os.path.basename(f)}`: `{un}`")
w("")

# ------------------------------------------------------------------ perf ---
w("## 1. perf: sort_v1 unsorted vs sorted\n")
perf = [r for r in runs if r["test"] == "perf"]
if perf:
    # newest run per kernel+program
    latest = {}
    for r in perf:
        k = (r["kernel"], r["condition"])
        if k not in latest or r["date"] > latest[k]["date"]:
            latest[k] = r
    w("| kernel | program | elapsed (s) | instructions | cycles | IPC | branches | branch-misses | miss rate |")
    w("|---|---|---|---|---|---|---|---|---|")
    for (k, p), r in sorted(latest.items()):
        br, bm = num(r["branches"]), num(r["branch_misses"])
        rate = f"{100 * bm / br:.2f}%" if br and bm is not None else "–"
        w(f"| {k} | {p} | {r['elapsed_s']} | {fmt(num(r['instructions']))} | {fmt(num(r['cycles']))} | "
          f"{r['ipc']} | {fmt(br)} | {fmt(bm)} | {rate} |")
    for k in ("stock", "rt"):
        u, s = latest.get((k, "sort_v1")), latest.get((k, "sort_v1_sorted"))
        if u and s and num(u["elapsed_s"]) and num(s["elapsed_s"]):
            w(f"\n- {k}: sorting first makes the loop **{num(u['elapsed_s']) / num(s['elapsed_s']):.2f}× faster**"
              + (f"; branch-misses drop {num(u['branch_misses']) / max(num(s['branch_misses']), 1):,.0f}×"
                 if num(u["branch_misses"]) and num(s["branch_misses"]) else "") + ".")
    if ("stock", "sort_v1") in latest and ("rt", "sort_v1") in latest:
        a, b = num(latest[("stock", "sort_v1")]["elapsed_s"]), num(latest[("rt", "sort_v1")]["elapsed_s"])
        if a and b:
            w(f"- RT vs stock, unsorted: {100 * (b - a) / a:+.1f}% elapsed time (RT targets latency, not throughput).")
else:
    w("_No perf results yet._")
w("")

# ------------------------------------------------------------ cyclictest ---
w("## 2. cyclictest wake-up latency (µs)\n")
cyc = [r for r in runs if r["test"] == "cyclictest"]
if cyc:
    latest_stamp = {}
    for r in cyc:
        k = (r["kernel"], r["condition"])
        latest_stamp[k] = max(latest_stamp.get(k, ""), r["date"])
    w("| kernel | condition | min | avg (mean of threads) | max (worst thread) | max per thread | overflows >499 µs |")
    w("|---|---|---|---|---|---|---|")
    order = {"check_unloaded": 0, "hist_unloaded": 1, "hist_loaded": 2}
    for (k, c), st in sorted(latest_stamp.items(), key=lambda kv: (kv[0][0] != "stock", order.get(kv[0][1], 9))):
        rows = [r for r in cyc if r["kernel"] == k and r["condition"] == c and r["date"] == st]
        mins = [num(r["min_us"]) for r in rows]
        avgs = [num(r["avg_us"]) for r in rows]
        maxs = [num(r["max_us"]) for r in rows]
        ovs = [num(r["overflows"]) or 0 for r in rows]
        w(f"| {k} | {c} | {fmt(min(mins))} | {sum(avgs) / len(avgs):.1f} | **{fmt(max(maxs))}** | "
          f"{' / '.join(fmt(m) for m in maxs)} | {fmt(sum(ovs))} |")
    w("\nThe max column matters most: averages are similar on both kernels, the worst case is not. "
      "Overflows are samples beyond the 500-bin histogram, so the true max is in the max column, not the chart.")
else:
    w("_No cyclictest results yet._")
w("")

# histogram compare CSV (newest full run folder per kernel)
hist = defaultdict(dict)   # (kernel_cond) -> {lat: count}
for kt in ("stock", "rt"):
    dirs = sorted((d for R in DIRS for d in glob.glob(os.path.join(R, f"{kt}_*")) if os.path.isdir(d) and not d.endswith("_QUICK")),
                  key=os.path.basename)
    for cond in ("hist_unloaded", "hist_loaded"):
        for d in reversed(dirs):
            f = os.path.join(d, f"hist_{cond}.csv")
            if os.path.exists(f):
                for row in read_csv(f):
                    lat = int(row["latency_us"])
                    hist[f"{kt}_{cond[5:]}"][lat] = sum(int(v) for kk, v in row.items() if kk.startswith("T"))
                break
if hist:
    cols = [c for c in ("stock_unloaded", "stock_loaded", "rt_unloaded", "rt_loaded") if c in hist]
    lats = sorted({l for c in cols for l in hist[c]})
    with open(os.path.join(RES, "hist_compare.csv"), "w", newline="") as f:
        cw = csv.writer(f)
        cw.writerow(["latency_us"] + cols)
        for l in lats:
            cw.writerow([l] + [hist[c].get(l, 0) for c in cols])
    w(f"Histogram data for Excel: `hist_compare.csv` ({', '.join(cols)}; counts summed over 4 threads).")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(9, 4.5))
        for c in cols:
            xs = [l for l in lats if hist[c].get(l, 0) > 0]
            ax.plot(xs, [hist[c][l] for l in xs], label=c.replace("_", " "), lw=1.2)
        ax.set_yscale("log"); ax.set_xlabel("latency (µs)"); ax.set_ylabel("samples (log)")
        ax.set_title("cyclictest -p 90 -m -h 500 -t4 -l 300000"); ax.legend(); ax.grid(alpha=.3)
        fig.tight_layout(); fig.savefig(os.path.join(RES, "hist_compare.png"), dpi=150)
        w("Chart: `hist_compare.png`.")
    except ImportError:
        w("(Install matplotlib for an automatic PNG, or chart the CSV in Excel.)")
    w("")

# ----------------------------------------------------------------- waves ---
w("## 3. Square waves on GPIO 13 (oscilloscope)\n")
if waves:
    groups = defaultdict(list)
    for r in waves:
        groups[(r["kernel"], r["program"], r["load"])].append(r)
    w("### Highest stable frequency (within 10% of expected)\n")
    w("| kernel | program | load | highest stable measured (Hz) | at setting | policy / priority |")
    w("|---|---|---|---|---|---|")
    for (k, p, l), rows in sorted(groups.items()):
        ok = [r for r in rows if r["stable_10pct"] == "yes" and num(r["measured_hz"])]
        meas = [r for r in rows if num(r["measured_hz"])]
        if ok:
            best = max(ok, key=lambda r: num(r["measured_hz"]))
            hz, st = fmt(num(best["measured_hz"])), best["setting"]
        elif meas and p == "test_rt_v16":
            best = max(meas, key=lambda r: num(r["measured_hz"]))
            hz, st = fmt(num(best["measured_hz"])) + " (no formula; check stability notes)", best["setting"]
        else:
            hz, st = "none stable", "–"
        pol = sorted({f"{r['policy']} / {r['priority']}" for r in rows if r["policy"]})
        w(f"| {k} | {p} | {l} | {hz} | {st} | {', '.join(pol) or '–'} |")
    w("\n### All readings\n")
    w("| kernel | program | load | setting | expected Hz | measured Hz | error % | stable | note |")
    w("|---|---|---|---|---|---|---|---|---|")
    for (k, p, l), rows in sorted(groups.items()):
        for r in rows:
            w(f"| {k} | {p} | {l} | {r['setting']} | {r['expected_hz'] or '–'} | {r['measured_hz'] or 'skip'} | "
              f"{r['error_pct'] or '–'} | {r['stable_10pct'] or '–'} | {r['note']} |")
else:
    w("_No oscilloscope readings yet._")
w("")

# ------------------------------------------------------------- chrt table ---
w("## 4. Scheduling (chrt) for the final square-wave tests\n")
w("| kernel | program | load | policy | priority |")
w("|---|---|---|---|---|")
seen = set()
for r in waves:
    key = (r["kernel"], r["program"], r["load"], r["policy"], r["priority"])
    if r["policy"] and key not in seen:
        seen.add(key); w("| " + " | ".join(key) + " |")
w("| (any) | sort_v1 load | loaded | SCHED_OTHER | 0 |  ← see `sched_snapshots.txt` / `chrt_snapshots.txt` |")
w("")

# ---------------------------------------------------------- missing items ---
w("## 5. Checklist: what is still missing\n")
have_c = {(r["kernel"], r["condition"]) for r in cyc}
have_p = {(r["kernel"], r["condition"]) for r in perf}
have_w = {(r["kernel"], r["program"], "loaded" if r["load"].startswith("loaded") else "unloaded")
          for r in waves if num(r["measured_hz"])}
need = []
for k in ("stock", "rt"):
    for p in ("sort_v1", "sort_v1_sorted"):
        need.append((f"perf {p} [{k}]", (k, p) in have_p))
    for c in ("check_unloaded", "hist_unloaded", "hist_loaded"):
        need.append((f"cyclictest {c} [{k}]", (k, c) in have_c))
for prog, ks in (("python3", ["stock"]), ("blink_v7", ["stock", "rt"]), ("test_rt_v16", ["rt"])):
    for k in ks:
        for l in ("unloaded", "loaded"):
            need.append((f"scope {'blink_v3.py' if prog == 'python3' else prog} {l} [{k}]", (k, prog, l) in have_w))
for label, ok in need:
    w(f"- [{'x' if ok else ' '}] {label}")
w("\nAlso for the TA: SD-card backups (compiled + installed RT), scope screenshots, htop screenshot under load.")

# -------------------------------------------------------------- archived ---
if ARCH:
    w("\n## Archived logs (older runs, not from this kit)\n")
    for f in sorted(glob.glob(os.path.join(ARCH, "**", "*.txt"), recursive=True)):
        txt = open(f, errors="replace").read()
        mx = re.search(r"# Max Latencies:\s*(.*)", txt)
        if mx:
            ov = re.search(r"# Histogram Overflows:\s*(.*)", txt)
            av = re.search(r"# Avg Latencies:\s*(.*)", txt)
            w(f"- `{os.path.relpath(f, ARCH)}`: max {[int(x) for x in mx.group(1).split()]}, "
              f"avg {[int(x) for x in av.group(1).split()] if av else '?'}, "
              f"overflows {[int(x) for x in ov.group(1).split()] if ov else '?'}")
        el = re.search(r"([\d.]+) seconds time elapsed", txt)
        if el and "Performance counter stats" in txt:
            bm = re.search(r"([\d,]+)\s+branch-misses", txt)
            ipc = re.search(r"([\d.]+)\s+insn per cycle", txt)
            w(f"- `{os.path.relpath(f, ARCH)}`: {el.group(1)} s, IPC {ipc.group(1) if ipc else '?'}, "
              f"branch-misses {bm.group(1) if bm else '?'}")

path = os.path.join(RES, "REPORT.md")
with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
print(f"Wrote {path}")
