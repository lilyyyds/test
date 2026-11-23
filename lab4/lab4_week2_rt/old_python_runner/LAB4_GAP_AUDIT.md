# Lab 4 evidence audit / 已有数据与缺项

Reference: `lab4_files/Lab 4_Fall2026_v5.pdf`, especially PDF pages 3–10 (Week 1), 28 (Week 2 numerical tests), 29–31 (RT square waves and final scheduling comparisons). This audit concerns files found in your lab folder, not proof that an unrecorded experiment was never performed.

## Existing evidence / 已经有的

| Requirement | Evidence found | Assessment |
|---|---|---|
| Stock and RT unsorted/sorted perf | `c_tests/perf_stock_unsorted.txt`, `perf_stock_sorted.txt`, `perf_rt_unsorted.txt`, `perf_rt_sorted.txt` | Present. Hardware branch events are unavailable in some logs; do not invent branch-miss rates. |
| Stock unloaded histogram | `hist_stock_idle.txt` | Present, including latency values above the 500 µs histogram range. |
| RT unloaded/loaded cyclictest | `c_tests/cyclic_rt_unloaded.txt`, `cyclic_rt_loaded.txt` | Present; four threads, 300,000 samples each when bin totals and overflows are counted. Retest improves provenance and verifies sustained load. |
| RT scheduling and loading snapshots | `c_tests/test2_chrt.txt`, `test4_chrt.txt` | RT kernel identifier and FIFO/49 versus OTHER/0 evidence; loading snapshots contain 20 sort processes. A snapshot alone does not prove continuous full load. |
| Build/patch/module logs | Top-level `make.log`, `patch.log`, `modules_install.log` | Present. Logs alone do not prove successful boot, exact source/patch compatibility or SD backup. |
| Waveform implementations | `blink_v7.c`, `test_rt_v16.c`, executables | Present. Source code does not replace scope measurements. |

Your older nested `lab4_files_f26/logs` contains 6.1.93-rt32 material. Keep it labelled separately from the current 6.18.57-rt7 work. Do not mix old reference logs into current results.

Existing archived cyclictest summary (microseconds; these are **old measurements**, not new results):

| Condition | Max per thread | Average per thread | Overflow counts |
|---|---|---|---|
| Stock unloaded | 2605, 1880, 2119, 2697 | 9, 10, 10, 9 | 7, 8, 1, 2 |
| RT unloaded | 54, 110, 98, 72 | 13, 12, 12, 11 | 0, 0, 0, 0 |
| RT loaded | 68, 80, 72, 68 | 11, 13, 12, 11 | 0, 0, 0, 0 |

These observations suggest reduced extreme wake-up delays in the recorded RT runs. They do not establish a universal bound or prove identical test environments. Mean latency alone would miss the large stock outliers.

## Gaps and disposition / 缺什么，怎么处理

| Evidence needed | Can current RT automation supply it? | Next action |
|---|---|---|
| Fresh RT perf measurements and exact build commands | Yes | Included, three paired repeats, preserve N/A events. |
| Fresh RT unloaded/loaded histograms and scheduling | Yes | Included, matching parameters, measured CPU utilization. |
| Histogram plots and overflow accounting | Yes | CSV always; PNG when matplotlib is installed. If Excel output is required, import CSV and retain the workbook. |
| Stock loaded cyclictest histogram | No | Not located in reviewed folder; retrieve old result or later boot a preserved stock system. |
| Python/C frequency sweeps on original kernel, unloaded/loaded | No | Retrieve original observations or measure on stock later. |
| RT test_rt_v16 interval sweep and frequency “knee” | Scope required | Deferred by your choice. Measure interval/frequency/stability, including the handout's 1500 reference; do not assume exactly 60 kHz. |
| Final RT 2500 unloaded/loaded comparison | Scope required | Deferred. Same interval in both conditions; record frequency, period variation and screenshots. |
| blink_v7 unloaded/loaded final comparison | Scope required | Deferred. Same timing setting; capture its chrt result while running. |
| Final waveform chrt table | Partial | New script captures sorts/cyclictest only. Preserve old RT FIFO49 and blink OTHER0 evidence; later capture waveform policies again. |
| SD backups and exact kernel source/configuration evidence | No | Verify separately; not found as backup artifacts in this folder. |

Do not run `capture.sh` together with the new runner. The existing script uses repeatedly relaunched load processes and lacks the same owned-process cleanup; independent leftover workloads would invalidate the unloaded baseline.

## Scope of this delivery / 本次完成范围

The new script runs only current-RT numerical tests. It never replaces old logs, installs/patches a kernel, edits boot settings, starts GPIO waveforms or claims the entire lab is complete. The remaining scope work is explicit so your report can distinguish **measured**, **missing**, and **deferred** evidence.
