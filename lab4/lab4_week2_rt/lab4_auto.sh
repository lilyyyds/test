#!/usr/bin/env bash
# =============================================================================
# lab4_auto.sh  —  ECE 5725 Lab 4 automatic tests (no oscilloscope needed)
#
# Runs on BOTH kernels. It detects stock vs PREEMPT_RT from `uname -v` and
# labels every result with it, so run it once on each SD card / kernel.
#
#   1. Environment snapshot   (uname, cmdline, config.txt, df -h, temps ...)
#   2. Build sort_v1 (unsorted) and sort_v1_sorted (-DSORTED)
#   3. perf stat on both, repeated (default 3x, idle system)
#   4. cyclictest 10k-loop check           (handout: -p 90 -m -t4 -l 10000)
#   5. cyclictest histogram, UNLOADED      (handout: -p 90 -m -h 500 -t4 -l 300000)
#   6. cyclictest histogram, LOADED with N persistent sort_v1 loops (default 20)
#      + per-core CPU %, temperature and throttle flags logged every 2 s
#      + ps / chrt snapshots of sort_v1 and cyclictest threads
#   7. Histogram CSVs (open in Excel), summary.md, and one row per result
#      appended to results/ALL_RUNS.csv so stock vs RT compare in one sheet.
#
# Usage:
#   sudo ./lab4_auto.sh                 full run  (~25-35 min)
#   sudo ./lab4_auto.sh --quick         pipeline check, 2000 loops (NOT lab data)
#   options: --loops N   cyclictest histogram loops   (default 300000)
#            --load N    number of sort_v1 loops      (default 20)
#            --repeats N perf repeats                 (default 3)
#            --skip-perf / --skip-cyclic
#
# Ctrl+C at any time: the load processes this script started are stopped.
# Needs: gcc, perf, cyclictest (rt-tests), chrt. Keep sort_v1.c next to it.
# =============================================================================
set -u

LOOPS=300000; LOAD=20; REPEATS=3; DO_PERF=1; DO_CYC=1; QUICK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)       QUICK=1; LOOPS=2000; REPEATS=1 ;;
    --loops)       LOOPS="$2"; shift ;;
    --load)        LOAD="$2"; shift ;;
    --repeats)     REPEATS="$2"; shift ;;
    --skip-perf)   DO_PERF=0 ;;
    --skip-cyclic) DO_CYC=0 ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo $0 $*"; exit 1; }

KIT="$(cd "$(dirname "$0")" && pwd)"
RUN_USER="${SUDO_USER:-pi}"
if uname -v | grep -q PREEMPT_RT; then KTAG=rt; else KTAG=stock; fi
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$KIT/results/${KTAG}_${STAMP}"; [[ $QUICK -eq 1 ]] && OUT="${OUT}_QUICK"
BUILD="$OUT/build"
mkdir -p "$BUILD"
chown -R "$RUN_USER":"$RUN_USER" "$KIT/results" 2>/dev/null
ALL="$KIT/results/ALL_RUNS.csv"
[[ $QUICK -eq 1 ]] && ALL="$KIT/results/ALL_RUNS_QUICK.csv"   # keep pipeline checks out of lab data
LOG="$OUT/run.log"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
die()  { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- cleanup ---
LOAD_PGIDS=(); MON_PID=""
stop_load() {
  local g
  for g in "${LOAD_PGIDS[@]:-}"; do [[ -n "$g" ]] && kill -TERM -- "-$g" 2>/dev/null; done
  sleep 1
  for g in "${LOAD_PGIDS[@]:-}"; do [[ -n "$g" ]] && kill -KILL -- "-$g" 2>/dev/null; done
  LOAD_PGIDS=()
}
stop_mon() { [[ -n "$MON_PID" ]] && kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null; MON_PID=""; }
cleanup() {
  stop_mon; stop_load
  pkill -x cyclictest 2>/dev/null
  chown -R "$RUN_USER":"$RUN_USER" "$KIT/results" 2>/dev/null
}
trap cleanup EXIT
trap 'log "Interrupted - cleaning up"; exit 130' INT TERM

# -------------------------------------------------------------- preflight ---
log "Lab 4 auto test  |  kernel tag: $KTAG  |  output: $OUT"
[[ -f "$KIT/sort_v1.c" ]] || die "sort_v1.c must be in $KIT"
for c in gcc chrt ps; do command -v "$c" >/dev/null || die "missing '$c'"; done
if [[ $DO_PERF -eq 1 ]] && ! perf --version >/dev/null 2>&1; then
  log "WARNING: perf not working (try: sudo apt install linux-perf). Skipping perf."; DO_PERF=0
fi
if [[ $DO_CYC -eq 1 ]] && ! command -v cyclictest >/dev/null; then
  log "WARNING: cyclictest missing (sudo apt install rt-tests). Skipping cyclictest."; DO_CYC=0
fi
BUSY=$(pgrep -a -x 'sort_v1|sort_v1_sorted|cyclictest|test_rt_v16|blink_v7' || true)
[[ -z "$BUSY" ]] || die "these test programs are already running, stop them first:
$BUSY"

# ------------------------------------------------------------ environment ---
{
  echo "=== date";            date
  echo "=== uname -a";        uname -a
  echo "=== kernel tag";      echo "$KTAG"
  echo "=== /proc/cmdline";   cat /proc/cmdline
  echo "=== kernel= line in config.txt"
  grep -Hn '^kernel=' /boot/firmware/config.txt /boot/config.txt 2>/dev/null || echo "(none -> default kernel8.img)"
  echo "=== preemption model"; grep -E 'CONFIG_PREEMPT_RT=|CONFIG_HZ=' "/boot/config-$(uname -r)" 2>/dev/null || zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_PREEMPT_RT=|CONFIG_HZ=' || echo "(kernel config not exposed)"
  echo "=== /sys/kernel/realtime"; cat /sys/kernel/realtime 2>/dev/null || echo "(absent)"
  echo "=== sched_rt_runtime_us"; cat /proc/sys/kernel/sched_rt_runtime_us
  echo "=== nproc";           nproc
  echo "=== cpu freq governor"; cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
  echo "=== df -h";           df -h
  echo "=== free -h";         free -h
  echo "=== temp";            vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp
  echo "=== throttled";       vcgencmd get_throttled 2>/dev/null || echo n/a
  echo "=== gcc";             gcc --version | head -1
  echo "=== perf";            perf --version 2>&1
  echo "=== cyclictest";      cyclictest --help 2>&1 | head -1
  echo "=== running non-kernel processes (top CPU)"; ps -eo pid,cls,rtprio,ni,pcpu,comm --sort=-pcpu | head -15
} > "$OUT/environment.txt" 2>&1
log "Kernel: $(uname -r)   ($(uname -v | grep -o 'PREEMPT[_A-Z]*' | head -1))"

# ------------------------------------------------------------------ build ---
cp "$KIT/sort_v1.c" "$OUT/sort_v1.c"
{
  echo "gcc -std=c99 -o sort_v1 sort_v1.c"
  gcc -std=c99 -o "$BUILD/sort_v1" "$KIT/sort_v1.c"
  echo "gcc -std=c99 -DSORTED -o sort_v1_sorted sort_v1.c"
  gcc -std=c99 -DSORTED -o "$BUILD/sort_v1_sorted" "$KIT/sort_v1.c"
} > "$OUT/build.log" 2>&1 || die "compile failed, see $OUT/build.log"
log "Built sort_v1 and sort_v1_sorted"

# -------------------------------------------------------- CPU/temp monitor --
# Writes: time,cpu0..cpuN busy%,temp_C,throttled   every 2 s
cpu_monitor() {
  local out="$1" name u n s i w q sq st rest idle total dt di row t thr hdr=time
  declare -A PT PI
  for ((k=0; k<$(nproc); k++)); do hdr+=",cpu$k"; done
  echo "$hdr,temp_C,throttled" > "$out"
  while :; do
    row="$(date +%H:%M:%S)"
    while read -r name u n s i w q sq st rest; do
      [[ $name =~ ^cpu[0-9]+$ ]] || continue
      idle=$((i + w)); total=$((u + n + s + i + w + q + sq + st))
      if [[ -n "${PT[$name]:-}" ]]; then
        dt=$((total - PT[$name])); di=$((idle - PI[$name]))
        if (( dt > 0 )); then row+=",$(( 100 * (dt - di) / dt ))"; else row+=",0"; fi
      fi
      PT[$name]=$total; PI[$name]=$idle
    done < /proc/stat
    t=$(awk '{printf "%.1f",$1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    thr=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    [[ "$row" == *,* ]] && echo "$row,${t:-},${thr:-}" >> "$out"
    sleep 2
  done
}
start_mon() { cpu_monitor "$1" & MON_PID=$!; }
mon_summary() {   # average busy % per core + max temp
  awk -F, 'NR==1{for(i=2;i<=NF;i++)h[i]=$i; next}
           {n++; for(i=2;i<=NF-2;i++)s[i]+=$i; if($(NF-1)>mt)mt=$(NF-1)}
           END{ if(!n){print "no samples"; exit}
                line="avg busy:"; for(i=2;i<=NF-2;i++) line=line sprintf(" %s=%.0f%%",h[i],s[i]/n);
                print line sprintf("  | max temp %.1f C | %d samples",mt,n)}' "$1"
}

# --------------------------------------------------------------- load gen ---
start_load() {   # $1 = number of persistent sort_v1 loops; ramped to be gentle
  local target=$1 step
  for step in 4 8 12 "$target"; do
    (( step > target )) && step=$target
    while (( ${#LOAD_PGIDS[@]} < step )); do
      # own session/process group, runs as the normal user, SCHED_OTHER
      setsid sudo -u "$RUN_USER" bash -c 'while :; do "$0" >/dev/null 2>&1; done' "$BUILD/sort_v1" &
      LOAD_PGIDS+=("$!"); disown "$!"
    done
    sleep 3
    (( step == target )) && break
  done
  log "Load running: ${#LOAD_PGIDS[@]} x sort_v1 loops"
}

# ------------------------------------------------------------------- perf ---
PERF_EVENTS="task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses"
perf_val() {  # $1=file $2=event -> value (no commas) or NA
  local v
  v=$(grep -E "[[:space:]]$2(:u)?[[:space:]]" "$1" | head -1 | awk '{print $1}' | tr -d ,)
  [[ "$v" =~ ^[0-9.]+$ ]] && echo "$v" || echo NA
}
if [[ $DO_PERF -eq 1 ]]; then
  [[ -f "$ALL" ]] || echo "date,kernel,test,condition,thread,min_us,avg_us,max_us,overflows,elapsed_s,instructions,cycles,branches,branch_misses,ipc" > "$ALL"
  sleep 5
  for prog in sort_v1 sort_v1_sorted; do
    log "perf stat -r $REPEATS ./$prog  (each run ~4-10 s)"
    ( cd "$BUILD" && sudo -u "$RUN_USER" perf stat -r "$REPEATS" -e "$PERF_EVENTS" -o "$OUT/perf_${prog}.txt" "./$prog" ) \
        > "$OUT/perf_${prog}_program_output.txt" 2>&1 \
      || ( cd "$BUILD" && perf stat -r "$REPEATS" -o "$OUT/perf_${prog}.txt" "./$prog" ) \
        > "$OUT/perf_${prog}_program_output.txt" 2>&1
    # also the handout's plain form, once, for the TA screenshot
    ( cd "$BUILD" && sudo -u "$RUN_USER" perf stat "./$prog" ) > "$OUT/perf_${prog}_plain.txt" 2>&1
    f="$OUT/perf_${prog}.txt"
    el=$(grep 'seconds time elapsed' "$f" | awk '{print $1}')
    ins=$(perf_val "$f" instructions); cyc=$(perf_val "$f" cycles)
    br=$(perf_val "$f" branches); bm=$(perf_val "$f" branch-misses)
    ipc=NA; [[ $ins != NA && $cyc != NA ]] && ipc=$(awk -v a="$ins" -v b="$cyc" 'BEGIN{printf "%.2f",a/b}')
    echo "$STAMP,$KTAG,perf,$prog,,,,,,${el:-NA},$ins,$cyc,$br,$bm,$ipc" >> "$ALL"
    log "  $prog: elapsed ${el:-?} s, IPC $ipc, branch-misses $bm"
  done
fi

# ------------------------------------------------------------- cyclictest ---
hist_to_csv() {  # cyclictest -h output -> latency_us,t0,t1,...
  awk 'BEGIN{OFS=","}
       /^[0-9]+[ \t]/ { if(!hdr){printf "latency_us"; for(i=2;i<=NF;i++) printf ",T%d", i-2; print ""; hdr=1}
                        line=$1+0; for(i=2;i<=NF;i++) line=line "," $i+0; print line }' "$1" > "$2"
}
cyc_field() { grep -E "^# $2" "$1" | tail -1 | sed "s/^# $2:[[:space:]]*//" ; }
record_cyc() {   # $1=logfile $2=condition
  local f=$1 cond=$2 mins avgs maxs ovs t=0
  read -ra mins <<< "$(cyc_field "$f" 'Min Latencies')"
  read -ra avgs <<< "$(cyc_field "$f" 'Avg Latencies')"
  read -ra maxs <<< "$(cyc_field "$f" 'Max Latencies')"
  read -ra ovs  <<< "$(cyc_field "$f" 'Histogram Overflows')"
  if [[ ${#maxs[@]} -eq 0 ]]; then   # no histogram: parse the T: lines
    while read -r line; do
      mins+=("$(sed -n 's/.*Min: *\([0-9]*\).*/\1/p' <<< "$line")")
      avgs+=("$(sed -n 's/.*Avg: *\([0-9]*\).*/\1/p' <<< "$line")")
      maxs+=("$(sed -n 's/.*Max: *\([0-9]*\).*/\1/p' <<< "$line")")
    done < <(grep -E '^T: *[0-9]' "$f")
  fi
  for t in "${!maxs[@]}"; do
    echo "$STAMP,$KTAG,cyclictest,$cond,$t,$((10#${mins[$t]:-0})),$((10#${avgs[$t]:-0})),$((10#${maxs[$t]:-0})),$((10#${ovs[$t]:-0})),,,,,," >> "$ALL"
  done
  local mx="" ov=""
  for t in "${!maxs[@]}"; do mx+="$((10#${maxs[$t]:-0})) "; ov+="$((10#${ovs[$t]:-0})) "; done
  log "  $cond  max us per thread: $mx | overflows: $ov"
}
snap_sched() {   # $1 = outfile, $2 = label
  {
    echo "== $2  $(date +%T)"
    echo "-- sort_v1 processes:"; ps -eo pid,user,cls,rtprio,ni,pri,psr,pcpu,comm | awk 'NR==1||/sort_v1/' | head -8
    echo "   (total sort_v1 running: $(pgrep -c -x sort_v1))"
    local sp; sp=$(pgrep -x sort_v1 | head -1)
    [[ -n "$sp" ]] && { echo "-- chrt -p $sp (sort_v1)"; chrt -p "$sp"; }
    echo "-- cyclictest threads:"; ps -eLo pid,tid,cls,rtprio,ni,psr,pcpu,comm | awk 'NR==1||/cyclictest/'
    local ct; ct=$(ps -eLo tid,rtprio,comm | awk '/cyclictest/ && $2!="-" {print $1; exit}')
    [[ -n "$ct" ]] && { echo "-- chrt -p $ct (cyclictest worker thread)"; chrt -p "$ct"; }
    echo
  } >> "$1" 2>&1
}
run_cyclic() {   # $1=condition label, rest = cyclictest args
  local cond=$1; shift
  local f="$OUT/cyclic_${cond}.txt"
  log "cyclictest $*   [$cond]"
  start_mon "$OUT/cpu_${cond}.csv"
  { echo "# command: cyclictest $*"; echo "# kernel: $(uname -a)"; } > "$f"
  ( TIMEFORMAT=$'real %R\nuser %U\nsys %S'; time cyclictest "$@" >> "$f" ) 2> "$OUT/cyclic_${cond}.stderr" &
  local cpid=$!
  sleep 5; snap_sched "$OUT/sched_snapshots.txt" "$cond"
  wait "$cpid"; local rc=$?
  stop_mon
  [[ $rc -eq 0 ]] || log "  WARNING: cyclictest exit code $rc (see cyclic_${cond}.stderr)"
  grep -E '^(real|user|sys)' "$OUT/cyclic_${cond}.stderr" | tr '\n' ' ' | sed 's/^/  time: /' | tee -a "$LOG"; echo
  log "  CPU during $cond: $(mon_summary "$OUT/cpu_${cond}.csv")"
  grep -q '^[0-9]\{6\}' "$f" && hist_to_csv "$f" "$OUT/hist_${cond}.csv"
  record_cyc "$f" "$cond"
}

if [[ $DO_CYC -eq 1 ]]; then
  [[ -f "$ALL" ]] || echo "date,kernel,test,condition,thread,min_us,avg_us,max_us,overflows,elapsed_s,instructions,cycles,branches,branch_misses,ipc" > "$ALL"
  CHECK_LOOPS=10000; [[ $QUICK -eq 1 ]] && CHECK_LOOPS=1000
  run_cyclic check_unloaded  -p 90 -m -t4 -l "$CHECK_LOOPS" -q
  run_cyclic hist_unloaded   -p 90 -m -h 500 -t4 -l "$LOOPS" -q
  start_load "$LOAD"
  log "Warm-up 10 s under load"; sleep 10
  run_cyclic hist_loaded     -p 90 -m -h 500 -t4 -l "$LOOPS" -q
  stop_load
  log "Load stopped"
fi

# ---------------------------------------------------------------- summary ---
{
  echo "# Lab 4 auto results — $KTAG kernel"
  echo
  echo "- Date: $(date)"
  echo "- uname: \`$(uname -a)\`"
  echo "- Histogram loops: $LOOPS, load: $LOAD x sort_v1, perf repeats: $REPEATS"
  [[ $QUICK -eq 1 ]] && echo "- **QUICK RUN — pipeline check only, not lab data**"
  echo
  echo "## perf (sort_v1 unsorted vs sorted)"
  echo '```'
  for p in sort_v1 sort_v1_sorted; do
    [[ -f "$OUT/perf_$p.txt" ]] && { echo "--- $p"; grep -vE '^\s*$|^#' "$OUT/perf_$p.txt"; }
  done
  echo '```'
  echo
  echo "## cyclictest (µs)"
  echo
  echo "| condition | thread | min | avg | max | overflows (>499 µs) |"
  echo "|---|---|---|---|---|---|"
  grep "^$STAMP," "$ALL" 2>/dev/null | awk -F, '$3=="cyclictest"{printf "| %s | %s | %s | %s | %s | %s |\n",$4,$5,$6,$7,$8,$9}'
  echo
  echo "## CPU load during each run"
  for c in check_unloaded hist_unloaded hist_loaded; do
    [[ -f "$OUT/cpu_$c.csv" ]] && echo "- $c: $(mon_summary "$OUT/cpu_$c.csv")"
  done
  echo
  echo "## Files"
  echo "- \`hist_*.csv\` → Excel histogram (latency_us vs count per thread)"
  echo "- \`cyclic_*.txt\` raw cyclictest output, \`sched_snapshots.txt\` ps/chrt during runs"
  echo "- \`perf_*.txt\` perf (with -r repeats), \`perf_*_plain.txt\` handout-style single run"
  echo "- \`../ALL_RUNS.csv\` one row per result from every run on every kernel"
} > "$OUT/summary.md"

log "Done. Summary: $OUT/summary.md"
log "Compare kernels: open $ALL in Excel (filter by kernel / condition)."
