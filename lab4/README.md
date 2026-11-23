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

**No oscilloscope yet?** Run only the tests that don't need one:

```bash
cd ~/lab4_git/lab4/lab4_week1_stock && sudo bash week1_noscope.sh   # stock kernel
cd ~/lab4_git/lab4/lab4_week2_rt    && sudo bash week2_noscope.sh   # PREEMPT_RT kernel
```

Each runs the tool check, perf + cyclictest (~30 min) and REPORT.md without pausing. Later, `week1.sh` / `week2.sh` skip what is already done and only do the scope steps.

Each script asks before every step and remembers which steps are done. Results go to each folder's `results/`. The Week 2 report merges the Week 1 results into a stock-vs-RT `REPORT.md`. See each folder's README for details.

## Uploading results

After the tests (no sudo):

```bash
cd ~/lab4_git/lab4 && bash push_results.sh
```

Pushing needs a GitHub token that can write, even though the repo is public. Create a fine-grained token at <https://github.com/settings/tokens?type=beta> with repository access set to `lilyyyds/test` only and **Contents: Read and write**. Run `git config --global credential.helper store` once, then use `lilyyyds` as the username and paste the token as the password. After that you won't be asked again.
