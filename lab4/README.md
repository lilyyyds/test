# ECE 5725 Lab 4: stock kernel vs PREEMPT_RT

| Folder | Kernel | Run on the Pi |
|---|---|---|
| `lab4_week1_stock/` | original Raspberry Pi OS (Week 1) | `cd lab4/lab4_week1_stock && sudo bash week1.sh` |
| `lab4_week2_rt/` | PREEMPT_RT (Week 2) | `cd lab4/lab4_week2_rt && sudo bash week2.sh` |

Get it on the Pi:

```bash
cd ~ && git clone https://github.com/lilyyyds/test.git    # first time
cd ~/test && git pull                                      # later updates
```

Each script asks before every step and remembers which steps are done. Results go to each folder's `results/`. The Week 2 report merges the Week 1 results into a stock-vs-RT `REPORT.md`. See each folder's README for details.
