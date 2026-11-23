# Lab 4 RT automatic retest — design and implementation plan

User selected automatic data tests only; GPIO/scope tests are deferred. This implements that selection, without rebuilding the kernel or modifying archived experiments.

## Approach
A Python 3 standard-library supervisor owns all child process groups and timestamped outputs. GCC compiles the supplied SORTED-capable benchmark at -O0. Linux tools perform actual measurements; matplotlib is optional for plotting after measurements. No third-party Python orchestration dependency. A shell-only implementation would make structured summaries and resource monitoring harder; remote scope automation is outside the selected scope.

## Contract
- Require Linux/aarch64/PREEMPT_RT, root, four online cores, gcc/perf/cyclictest/chrt; missing dependencies stop with actionable messages, no automatic installs.
- Refuse known competing test processes and a concurrent harness. Do not kill unrelated processes.
- Save environment, commands, tool versions, source hash, timestamps, statuses, and diagnostics. Preserve old output.
- Compile separate unsorted/sorted binaries from the archived source; record exact flags. Execute three paired perf runs at idle; retain unsupported events as missing, never zero.
- Run a 10000-loop cyclictest check then unloaded and loaded 300000-loop histograms, priority 90, four threads, 500 bins. Explicit 1000us base interval and distance 0; no affinity changes. Record this normalization relative to handout defaults.
- Ramp persistent sort workers 1/4/8/12/20, monitor per-core CPU, temperature, undervoltage, available RAM, and timeouts. Default checks are conservative operational choices, not lab grading rules.
- Graceful interrupt/timeout cleanup, SIGKILL fallback only for owned groups. Power failure/SIGKILL cannot guarantee cleanup; new run refuses survivors. No automatic reboot/sysctl/boot/SD edits.
- Produce CSV, raw logs, JSON, Markdown; optional matplotlib PNG histogram with overflow/max annotations. Missing plotting capability is explicitly reported.
- Mark stage failures and loaded utilization shortfalls. Completed acquisition does not mean the whole lab is complete. Stock kernel data, GPIO readings, screenshots, and SD backups remain separate.

## Tasks
- [x] Test histogram overflow accounting, malformed/truncated output, unsupported perf values, CPU math, process-tree cleanup and command timeout.
- [x] Implement acquisition and resource-managed workloads.
- [x] Test against archived histograms, local process fixtures and syntax-check both variants of the supplied benchmark (never stress the local Mac).
- [x] Write requirement audit, setup/run guide, and verify package paths.
- [x] Independent review of process lifecycle, result validity, and user instructions; resolve important findings.

No Raspberry Pi or live kernel is connected here. Local testing cannot certify on-device RT latency or power stability.
