# Lab 4, Week 1: stock Raspberry Pi OS kernel

Boot the **stock** SD card, copy this folder to the Pi as `~/lab4_week1_stock`, then run:

```bash
cd ~/lab4_week1_stock
sudo bash lab4_auto.sh --quick     # optional 2-min check, saved separately (not lab data)
sudo bash week1.sh                 # guided: runs every Week 1 test in order
```

`week1.sh` asks before each step. It remembers finished steps, so you can quit (`q`) and run it again later to pick up where you stopped.

| Step | What | Scope? | Time |
|---|---|---|---|
| 1 | Check/install rt-tests, perf, htop, RPi.GPIO, pigpio; save `uname -a` | no | 1–5 min |
| 2 | perf `sort_v1` unsorted vs sorted, cyclictest 10k check, 300k histograms **unloaded and loaded** (20× sort_v1) | no | ~30 min |
| 3 | `blink_v3.py` sweep 10 Hz → 20 kHz, unloaded then loaded | yes | ~15 min |
| 4 | `blink_v7` sweep (half-period 500000 → 1000 ns, i.e. 1 kHz → 500 kHz), unloaded then loaded | yes | ~15 min |
| 5 | Build `results/REPORT.md` | no | seconds |

**No oscilloscope?** `sudo bash week1_noscope.sh` runs only the tool check, perf + cyclictest and the report, with no pauses (`--quick` for a 2-min check, `--load 8` for a lighter load).

Other commands:

```bash
sudo bash week1.sh --list          # what's done
sudo bash week1.sh --step 3        # redo one step
sudo bash week1.sh --load 8        # fewer sort_v1 copies if the Pi rebooted under 20
```

Scope steps: probe on **GPIO 13 (physical pin 33)**, ground clip on GND. At each prompt, type the frequency the scope shows (`950`, `12.3k`, `0.5M`), `r` to re-run, `s` to skip, or `q` to quit. `blink_v7` stops itself after 100 s, so read the scope within that time or press `r`.

## Results (`results/`)

- `REPORT.md`: perf / cyclictest / scope tables plus a checklist of what's still missing
- `ALL_RUNS.csv`, `ALL_WAVES.csv`: every reading, ready for Excel
- `hist_compare.csv`: latency histogram columns for the Excel chart
- `stock_<time>/`: raw cyclictest/perf output, `cpu_*.csv` (core load and temperature), `sched_snapshots.txt`
- `wave_stock_<prog>_<time>/`: scope readings and `chrt_snapshots.txt`

Week 2 lives in `../lab4_week2_rt`. Copy this folder back to the laptop (or keep both on the Pi side by side) so the Week 2 report can merge these results in automatically.
