# Lab 4, Week 2: PREEMPT_RT kernel (`week2.sh`)

Boot the **RT** SD card (`uname -v` must show `PREEMPT_RT`). Copy this folder to the Pi as `~/lab4_week2_rt`, ideally next to `~/lab4_week1_stock`, then run:

```bash
cd ~/lab4_week2_rt
sudo bash lab4_auto.sh --quick     # optional 2-min check (saved separately, not lab data)
sudo bash week2.sh                 # guided: runs every Week 2 test in order
```

| Step | What | Scope? | Handout |
|---|---|---|---|
| 1 | Check tools, save `uname -a` (TA checklist) | no | p.31 checklist |
| 2 | cyclictest 10k + 300k histograms unloaded/loaded, perf both sort versions | no | p.28 |
| 3 | `test_rt_v16` interval sweep 5000 → 100, unloaded then loaded (find the knee; 1500 ≈ 60 kHz) | yes | p.30 |
| 4 | Final tests 1+2: `test_rt_v16 2500` unloaded vs loaded, chrt recorded | yes | p.31 |
| 5 | Final tests 3+4: `blink_v7` unloaded vs loaded, chrt recorded | yes | p.31 |
| 6 | Optional: `blink_v3.py` on RT | yes | — |
| 7 | `results/REPORT.md`, stock vs RT (merges `../lab4_week1_stock/results`) | no | write-up |

Use `--list`, `--step N`, `--from N` and `--load N` the same way as in Week 1.

`old_python_runner/` holds your earlier RT-only Python runner (`run_rt_tests.py`). It runs the same numerical tests as step 2, so you don't need it. Use one or the other, and never both at once.

To build the combined report on the laptop after copying both `results/` folders back:

```bash
python3 lab4_report.py results --with ../lab4_week1_stock/results --archive ../lab4_files
```
