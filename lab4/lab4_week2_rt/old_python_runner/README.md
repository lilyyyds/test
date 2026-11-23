# Lab 4: RT automatic retest / RT 全自动重测

This package measures the numerical tests possible on your current PREEMPT_RT Raspberry Pi 4B. It does **not** complete all Lab 4 requirements: GPIO waveforms require an oscilloscope, and the stock-kernel comparison requires stock-kernel evidence.

中文：这是“RT 系统自动数据采集”，不是刷系统脚本。不会修改内核、启动配置或 GPIO，也不会删除旧实验数据。

## Run on the Pi / 在树莓派运行

Copy this entire folder to the Pi, for example to `/home/pi/lab4_rt_retest`. The included `sort_v1.c` is copied unchanged from your completed lab folder. Keep it beside `run_rt_tests.py`.

Open a terminal **on the Pi**, then:

```bash
cd ~/lab4_rt_retest
python3 run_rt_tests.py --plan
sudo python3 run_rt_tests.py
```

The second command only displays the plan. The third performs the full experiment. Allow approximately 12–18 minutes; slower systems may take longer. Keep the terminal connected. Use Ctrl+C to stop; the script cleans up the workload processes it created. Power loss or a system crash cannot be handled by a cleanup routine.

先关闭你以前手动启动的 sort、blink、test_rt 和 cyclictest。脚本检测到这些进程会停止并显示 PID，不会替你随意 kill。以前出现过满载后重启，因此这次逐步加负载，并记录温度、内存和供电/降频标志；这些检查不能保证硬件不重启。若再次重启，不要不断重跑，先检查电源、散热及日志。

Required tools: Python 3.8+, gcc, perf, cyclictest, chrt, ps, bash. Optional: matplotlib for PNG charts and vcgencmd for Pi health flags. Missing dependencies are reported without installing anything. On Raspberry Pi OS/Debian, the relevant package names commonly include `build-essential`, `linux-perf`, `rt-tests`, `util-linux`, and `python3-matplotlib`; use packages matching your installed OS/kernel. Do not change distribution or kernel to satisfy a missing package.

Optional shortened pipeline check:

```bash
sudo python3 run_rt_tests.py --quick
```

**Quick mode still ramps to 20 load workers**, but records only 1,000 samples per thread rather than 300,000. It is not valid final lab data. Exit code 2 is expected for a quick run, since it is explicitly not a full acquisition.

## What runs / 自动测什么

1. Record kernel, OS, compiler, tool versions, free disk/RAM, source hash and kernel messages. Require PREEMPT_RT, 64-bit Linux, four online cores and adequate RAM/disk.
2. Build unsorted and `-DSORTED` versions of the same teacher sorting source using `-O0`. This matters because the original calculation can otherwise be optimized away. Preserve compiler warnings and commands.
3. Probe perf events; run three paired unsorted/sorted measurements without deliberate load. Preserve unsupported events as **N/A**, not zero. Save raw counters, program output and runner wall time. Raw perf scaling percentages matter when counters are multiplexed.
4. Run a 10,000-loop cyclictest check, then a 300,000-loop unloaded histogram for four threads.
5. Ramp persistent sort workers through 1, 4, 8, 12, 20 with warm-up; record CPU usage for each core, memory and temperature. Each wrapper starts another sort when the previous finite sort finishes, maintaining load throughout the measurement.
6. Record the load process list and `chrt`, then run the same 300,000-loop cyclictest under load. Capture cyclictest thread scheduling too.
7. Stop only this run's process groups; validate histogram totals including overflows; export CSV, JSON, a Markdown report and a PNG if matplotlib is installed.

Cyclictest parameters:

```text
-p 90 -m -t4 -i 1000 -d 0 -q -h 500 -l 300000
```

All threads use a 1,000 µs interval. **Explicit `-d 0` is a script choice** to remove version-dependent/default spacing ambiguity; the handout leaves these interval settings implicit. Compare with old runs only after checking their logged intervals and settings. No CPU affinity is imposed.

The monitor samples CPU approximately every 2 seconds. The report's load check asks whether every core was at least 90% busy in at least 90% of those samples. This is our quality check, **not a teacher requirement** and not proof of continuous saturation. Failed load validation means review/retest, not “full load succeeded”. Monitoring adds small background overhead, including to the nominally unloaded measurement.

## Results / 结果在哪里

Each invocation creates a new directory:

```text
lab4_rt_results/YYYYMMDD_HHMMSS_PID/
```

Start with `REPORT.md` and `state.json`:

| Output | Meaning / 用途 |
|---|---|
| `REPORT.md` | Summary, remaining lab work, warnings / 总结与未完成项 |
| `cyclic_*_summary.json` | Each thread's min/average/max latency and overflow counts |
| `cyclic_*_histogram.csv` | Import into Excel to plot or inspect the distribution |
| `cyclic_*.log` | Full original cyclictest output |
| `latency_histograms.png` | Plot if matplotlib is available; max/overflows remain visible in annotations |
| `perf_summary.json`, `perf_*.csv`, `perf_*.log` | Paired sorting measurements, raw counters and original output |
| `*_scheduling.txt`, `load_chrt.txt` | Actual scheduling policy and priority; inspect errors/missing snapshots |
| `health.jsonl`, `load_validation.json` | Per-core utilization, memory, temperature and load validation |
| `commands.json`, `environment.txt`, `source.c`, `source.sha256` | Exact commands and reproducibility evidence |
| `kernel_dmesg_*.log`, `throttling.log` | Troubleshooting evidence, when available |

Exit 0 means full acquisition plus load validation passed. Exit 2 means quick-only, interrupted/failed acquisition, or load review required. Exit 1 means startup/preflight failed. Always inspect the report: successful acquisition does not mean every hardware perf event or optional plot was available. A folder left with `status: running` after a reboot is incomplete evidence.

## What these experiments mean / 为什么做

- **sort + perf:** the same conditional calculation processes random versus sorted data. This explores CPU branch prediction and throughput. Sorting is also a convenient CPU load generator. It is not a direct real-time latency test.
- **cyclictest:** a thread requests periodic wake-ups and measures how late it actually resumes. Lower worst observed latency and fewer extreme outliers are valuable for real-time response. The observed maximum is not a proven hard worst-case bound.
- **Loaded versus unloaded:** asks how competing CPU work changes wake-up latency. Twenty processes do not automatically prove four cores are fully busy, which is why we log CPU usage.
- **chrt:** records scheduling policy and real-time priority, not CPU utilization. The sorting workload normally uses SCHED_OTHER/priority 0; cyclictest worker threads request FIFO/90. Read the actual captured result.
- **PREEMPT_RT:** aims to improve predictability of scheduling/interrupt response. It does not imply all applications run faster or all deadlines are guaranteed.

## Validation performed before delivery

Parser/process-management tests run on the Mac; existing archived cyclictest data are checked against the parser. This package has not been run against the physical Pi during preparation. The first actual Pi run must still verify available tools, hardware performance counters, scheduling permissions and load behavior.

The archived C source emits existing warnings (`sizeof` printed with `%d`, and an unused computed sum). It is kept unchanged for traceability; both variants passed syntax checking. `-O0` is intentional.
