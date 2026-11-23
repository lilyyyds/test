#!/usr/bin/env bash
# =============================================================================
# lab4_wave.sh  —  ECE 5725 Lab 4 square-wave sweeps (you read the oscilloscope)
#
# For each setting it starts the square-wave program on GPIO 13, captures
# ps + chrt (scheduling policy/priority) while it runs, then asks you to type
# the frequency the scope shows. Results go to a CSV ready for the
# "expected vs measured frequency" plots. Works on stock and PREEMPT_RT.
#
# Usage:
#   sudo ./lab4_wave.sh py [freq_Hz ...]          blink_v3.py   (Python, RPi.GPIO)
#   sudo ./lab4_wave.sh c  [half_period_ns ...]   blink_v7      (C, pigpio, nanosleep)
#   sudo ./lab4_wave.sh rt [loop_interval ...]    test_rt_v16   (C, pigpio, SCHED_FIFO 49, busy loop)
#
#   --load N   after the unloaded pass, start N sort_v1 loops and repeat
#              every setting loaded (handout: 20). --load 0 = unloaded only.
#   --loaded-only N   skip the unloaded pass
#
# Examples (handout final tests):
#   sudo ./lab4_wave.sh rt 2500 1500 --load 20
#   sudo ./lab4_wave.sh c 500000 50000 10000 5000 --load 20
#   sudo ./lab4_wave.sh py 100 1000 5000 10000 --load 20
#
# At the prompt type what the scope reports: 1234, 12.3k, 0.76M, or
#   s = skip,  r = re-run this setting,  q = quit.
# GPIO 13 is hard-coded in the lab code (same pin as the Lab 3 PWM pin).
# =============================================================================
set -u

MODE="${1:-}"; shift || true
SETTINGS=(); LOAD=0; UNLOADED=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --load)        LOAD="$2"; shift ;;
    --loaded-only) LOAD="$2"; UNLOADED=0; shift ;;
    -h|--help)     sed -n '2,29p' "$0"; exit 0 ;;
    *)             SETTINGS+=("$1") ;;
  esac
  shift
done

case "$MODE" in
  py) [[ ${#SETTINGS[@]} -gt 0 ]] || SETTINGS=(10 100 500 1000 2000 5000 10000 20000) ;;
  c)  [[ ${#SETTINGS[@]} -gt 0 ]] || SETTINGS=(500000 100000 50000 20000 10000 5000 2000 1000) ;;
  rt) [[ ${#SETTINGS[@]} -gt 0 ]] || SETTINGS=(5000 2500 1500 1000 700 500 300 100) ;;
  *)  sed -n '2,29p' "$0"; exit 1 ;;
esac
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo $0 $MODE ${SETTINGS[*]}"; exit 1; }

KIT="$(cd "$(dirname "$0")" && pwd)"
RUN_USER="${SUDO_USER:-pi}"
if uname -v | grep -q PREEMPT_RT; then KTAG=rt; else KTAG=stock; fi
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="$KIT/results/wave_${KTAG}_${MODE}_${STAMP}"
BUILD="$OUT/build"; mkdir -p "$BUILD"
CSV="$OUT/wave_${MODE}.csv"
ALLW="$KIT/results/ALL_WAVES.csv"
SCHED="$OUT/chrt_snapshots.txt"
LOG="$OUT/run.log"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# ---------------------------------------------------------------- cleanup ---
LOAD_PGIDS=(); WAVE_PGID=""
stop_wave() {
  [[ -n "$WAVE_PGID" ]] || return
  kill -INT -- "-$WAVE_PGID" 2>/dev/null; sleep 1   # SIGINT lets pigpio terminate cleanly
  kill -0 -- "-$WAVE_PGID" 2>/dev/null && kill -KILL -- "-$WAVE_PGID" 2>/dev/null
  WAVE_PGID=""
}
stop_load() {
  local g; for g in "${LOAD_PGIDS[@]:-}"; do [[ -n "$g" ]] && kill -TERM -- "-$g" 2>/dev/null; done
  sleep 1; for g in "${LOAD_PGIDS[@]:-}"; do [[ -n "$g" ]] && kill -KILL -- "-$g" 2>/dev/null; done
  LOAD_PGIDS=()
}
cleanup() { stop_wave; stop_load; chown -R "$RUN_USER":"$RUN_USER" "$KIT/results" 2>/dev/null; }
trap cleanup EXIT
trap 'echo; log "Interrupted - cleaning up"; exit 130' INT TERM

# ------------------------------------------------------------------ build ---
command -v gcc >/dev/null || { echo "gcc missing"; exit 1; }
gcc -std=c99 -o "$BUILD/sort_v1" "$KIT/sort_v1.c" 2>>"$OUT/build.log" || { echo "sort_v1 build failed"; exit 1; }
case "$MODE" in
  py)
    PROG_NAME=python3
    python3 -c 'import RPi.GPIO' 2>/dev/null || { echo "RPi.GPIO not importable (sudo apt install python3-rpi-lgpio or python3-rpi.gpio)"; exit 1; } ;;
  c|rt)
    [[ -f /usr/local/include/pigpio.h || -f /usr/include/pigpio.h ]] || { echo "pigpio not installed - see handout p.9 (git clone joan2937/pigpio; make; sudo make install; sudo ldconfig)"; exit 1; }
    SRC=blink_v7.c; PROG_NAME=blink_v7
    [[ $MODE == rt ]] && { SRC=test_rt_v16.c; PROG_NAME=test_rt_v16; }
    echo "gcc -Wall -pthread -o $PROG_NAME $SRC -lpigpio -lrt" >> "$OUT/build.log"
    gcc -Wall -pthread -o "$BUILD/$PROG_NAME" "$KIT/$SRC" -lpigpio -lrt >> "$OUT/build.log" 2>&1 \
      || { echo "build failed, see $OUT/build.log"; exit 1; }
    if pgrep -x pigpiod >/dev/null; then
      log "pigpiod is running - C pigpio programs can't start while it runs (handout App. C). Stopping it."
      killall pigpiod; sleep 1
    fi ;;
esac
pgrep -a -x 'blink_v7|test_rt_v16|sort_v1|cyclictest' && { echo "Stop the programs above first."; exit 1; }

# -------------------------------------------------------------- helpers -----
expected_hz() {   # what the setting should produce, if known
  case "$MODE" in
    py) echo "$1" ;;
    c)  awk -v p="$1" 'BEGIN{printf "%.2f", 1e9/(2*p)}' ;;
    rt) echo "" ;;    # loop count -> no formula; Appendix E gives ~91 kHz @1000 on the TA Pi
  esac
}
to_hz() {   # 12.3k / 0.76M / 950 -> Hz
  awk -v v="$1" 'BEGIN{ m=1; u=tolower(substr(v,length(v)));
       if(u=="k"){m=1e3; v=substr(v,1,length(v)-1)} else if(u=="m"){m=1e6; v=substr(v,1,length(v)-1)}
       if(v !~ /^[0-9]*\.?[0-9]+$/) exit 1; printf "%.2f", v*m }'
}
start_wave() {   # $1 = setting
  case "$MODE" in
    py) setsid bash -c 'echo "$1" | exec python3 "$0"' "$KIT/blink_v3.py" "$1" > "$OUT/prog_$1.log" 2>&1 & ;;
    c)  setsid "$BUILD/blink_v7" "$1"     > "$OUT/prog_$1.log" 2>&1 & ;;
    rt) setsid "$BUILD/test_rt_v16" "$1"  > "$OUT/prog_$1.log" 2>&1 & ;;
  esac
  WAVE_PGID=$!; disown "$WAVE_PGID"
  sleep 2
}
snap() {   # $1 = label
  {
    echo "== $PROG_NAME $1   [$(date +%T)]"
    ps -L -s "$WAVE_PGID" -o pid,tid,user,cls,rtprio,ni,pri,psr,pcpu,comm
    local pid; pid=$(pgrep -s "$WAVE_PGID" -x "$PROG_NAME" | head -1)
    if [[ -n "$pid" ]]; then echo "-- chrt -p $pid ($PROG_NAME)"; chrt -p "$pid"
    else echo "!! $PROG_NAME not running (exited?) - output:"; tail -5 "$OUT/prog_${1%% *}.log"; fi
    if pgrep -x sort_v1 >/dev/null; then
      local sp; sp=$(pgrep -x sort_v1 | head -1)
      echo "-- sort_v1 running: $(pgrep -c -x sort_v1); chrt -p $sp"; chrt -p "$sp"
    fi
    echo
  } >> "$SCHED" 2>&1
}
start_load() {
  local n=$1 step
  for step in 4 8 12 "$n"; do
    (( step > n )) && step=$n
    while (( ${#LOAD_PGIDS[@]} < step )); do
      setsid sudo -u "$RUN_USER" bash -c 'while :; do "$0" >/dev/null 2>&1; done' "$BUILD/sort_v1" &
      LOAD_PGIDS+=("$!"); disown "$!"
    done
    sleep 2; (( step == n )) && break
  done
  log "Load running: ${#LOAD_PGIDS[@]} x sort_v1 (check htop in another terminal if you like)"
  sleep 5
}

[[ -f "$CSV" ]] || echo "date,kernel,program,load,setting,expected_hz,measured_hz,error_pct,stable_10pct,policy,priority,note" > "$CSV"
[[ -f "$ALLW" ]] || head -1 "$CSV" > "$ALLW"

run_pass() {   # $1 = load label ("unloaded" or "loaded_20")
  local cond=$1 s exp ans hz err ok pol pri note
  log "=== $PROG_NAME  |  $cond  |  settings: ${SETTINGS[*]}"
  for s in "${SETTINGS[@]}"; do
    while :; do
      start_wave "$s"
      snap "$s $cond"
      pid=$(pgrep -s "$WAVE_PGID" -x "$PROG_NAME" | head -1)
      pol=$(chrt -p "$pid" 2>/dev/null | awk -F': ' '/policy/{print $2}')
      pri=$(chrt -p "$pid" 2>/dev/null | awk -F': ' '/priority/{print $2}')
      exp=$(expected_hz "$s")
      echo
      echo "  >>> $PROG_NAME $s  [$cond]   expected: ${exp:-?} Hz   sched: ${pol:-?} / ${pri:-?}"
      [[ $MODE == c ]] && echo "      (blink_v7 stops itself after 100 s)"
      read -r -p "      Scope frequency (e.g. 950, 12.3k, 0.76M | s skip | r rerun | q quit): " ans
      note=""
      case "$ans" in
        q) stop_wave; log "Quit by user"; return 1 ;;
        r) stop_wave; continue ;;
        s|"") hz=""; note="skipped" ;;
        *) hz=$(to_hz "$ans") || { echo "      couldn't read '$ans' - try again"; stop_wave; continue; } ;;
      esac
      read -r -p "      Note (jitter/unstable/etc, Enter for none): " n2
      [[ -n "$n2" ]] && note="${note:+$note; }${n2//,/;}"
      stop_wave
      err=""; ok=""
      if [[ -n "$hz" && -n "$exp" ]]; then
        err=$(awk -v m="$hz" -v e="$exp" 'BEGIN{printf "%.1f", 100*(m-e)/e}')
        ok=$(awk -v x="$err" 'BEGIN{print (x<=10 && x>=-10) ? "yes" : "no"}')
      fi
      row="$STAMP,$KTAG,$PROG_NAME,$cond,$s,$exp,$hz,$err,$ok,$pol,$pri,$note"
      echo "$row" >> "$CSV"; echo "$row" >> "$ALLW"
      log "  recorded: setting=$s measured=${hz:-skip} Hz err=${err:-n/a}% stable=${ok:-n/a}"
      break
    done
  done
}

log "Kernel: $KTAG ($(uname -r))   program: $PROG_NAME   GPIO 13   output: $OUT"
{ uname -a; echo; cat "$OUT/build.log"; } > "$OUT/environment.txt"
if [[ $UNLOADED -eq 1 ]]; then run_pass unloaded || exit 0; fi
if [[ $LOAD -gt 0 ]]; then
  start_load "$LOAD"
  run_pass "loaded_$LOAD" || exit 0
  stop_load
fi
log "Done.  CSV: $CSV   (all sweeps: $ALLW)   chrt/ps evidence: $SCHED"
column -s, -t "$CSV" 2>/dev/null || cat "$CSV"
