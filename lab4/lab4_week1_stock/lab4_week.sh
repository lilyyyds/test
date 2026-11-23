#!/usr/bin/env bash
# =============================================================================
# lab4_week.sh  —  one guided script per lab week (ECE 5725 Lab 4)
#
#   sudo bash week1.sh      (stock Raspberry Pi OS kernel, Week 1)
#   sudo bash week2.sh      (PREEMPT_RT kernel, Week 2)
#
# Runs every Lab 4 test for that week in handout order, using lab4_auto.sh
# (perf + cyclictest, no scope) and lab4_wave.sh (scope sweeps, you type the
# frequency). After each step it asks to continue, and it remembers finished
# steps, so you can stop and come back later. At the end it builds
# results/REPORT.md with the stock-vs-RT tables (lab4_report.py).
#
# Options:
#   --list            show the steps and which are done, then exit
#   --step N          run only step N (re-runs it even if done)
#   --from N          start at step N (re-runs N and later)
#   --reset           forget which steps are done for this week
#   --load N          number of sort_v1 copies for loaded tests (default 20)
#   --yes             don't pause between steps
# =============================================================================
set -u

WEEK="${1:-}"; shift || true
[[ $WEEK == 1 || $WEEK == 2 ]] || { echo "usage: sudo bash lab4_week.sh 1|2 [options]  (or week1.sh / week2.sh)"; exit 1; }

ONLY=""; FROM=1; RESET=0; LIST=0; LOAD=20; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --step)  ONLY="$2"; shift ;;
    --from)  FROM="$2"; shift ;;
    --reset) RESET=1 ;;
    --list)  LIST=1 ;;
    --load)  LOAD="$2"; shift ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

KIT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$KIT/results"
STATE="$KIT/results/.week${WEEK}_done"
[[ $RESET -eq 1 ]] && rm -f "$STATE"
touch "$STATE"

if uname -v | grep -q PREEMPT_RT; then KTAG=rt; else KTAG=stock; fi

# ------------------------------------------------------------- step table ---
# Each step: "title|command". Commands run from $KIT.
if [[ $WEEK == 1 ]]; then
  WANT=stock
  STEPS=(
    "Install/check tools (rt-tests, perf, pigpio, RPi.GPIO)|preflight"
    "perf sort_v1 unsorted vs sorted + cyclictest 10k + 300k histograms unloaded & loaded (~30 min, no scope)|bash lab4_auto.sh --load $LOAD"
    "Scope: blink_v3.py (Python) sweep, unloaded then loaded|bash lab4_wave.sh py 10 100 500 1000 2000 5000 10000 20000 --load $LOAD"
    "Scope: blink_v7 (C, nanosleep) sweep, unloaded then loaded|bash lab4_wave.sh c 500000 100000 50000 20000 10000 5000 2000 1000 --load $LOAD"
    "Build REPORT.md (tables for the write-up)|report"
  )
else
  WANT=rt
  STEPS=(
    "Install/check tools + save 'uname -a' for the TA checklist|preflight"
    "cyclictest 10k + 300k histograms unloaded & loaded + perf sort_v1 both versions (~30 min, no scope)|bash lab4_auto.sh --load $LOAD"
    "Scope: test_rt_v16 interval sweep (find the knee; 1500 should be ~60 kHz), unloaded then loaded|bash lab4_wave.sh rt 5000 2500 1500 1000 700 500 300 100 --load $LOAD"
    "Scope: final tests 1+2 — test_rt_v16 2500 unloaded vs loaded (chrt recorded)|bash lab4_wave.sh rt 2500 --load $LOAD"
    "Scope: final tests 3+4 — blink_v7 unloaded vs loaded (chrt recorded)|bash lab4_wave.sh c 500000 50000 10000 5000 --load $LOAD"
    "Optional: blink_v3.py on the RT kernel, for comparison with week 1|bash lab4_wave.sh py 100 1000 5000 10000 --load $LOAD"
    "Build REPORT.md (stock vs RT tables)|report"
  )
fi
N=${#STEPS[@]}

is_done() { grep -qx "$1" "$STATE"; }
show_list() {
  echo "Week $WEEK steps (kernel now: $KTAG, this week expects: $WANT)"
  local i t
  for ((i=1; i<=N; i++)); do
    t="${STEPS[$((i-1))]%%|*}"
    if is_done "$i"; then echo "  [x] $i. $t"; else echo "  [ ] $i. $t"; fi
  done
}
if [[ $LIST -eq 1 ]]; then show_list; exit 0; fi

[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo bash $0 $WEEK $*"; exit 1; }
RUN_USER="${SUDO_USER:-pi}"

if [[ $KTAG != "$WANT" ]]; then
  echo "!! Week $WEEK should run on the $WANT kernel, but this Pi is running: $(uname -r) ($KTAG)."
  [[ $WEEK == 2 ]] && echo "   Boot the PREEMPT_RT SD card / kernel first (uname -v should say PREEMPT_RT)."
  [[ $WEEK == 1 ]] && echo "   Boot the stock Raspberry Pi OS SD card first."
  read -r -p "   Continue anyway? Results will be labelled '$KTAG'. [y/N] " a
  [[ $a == y || $a == Y ]] || exit 1
fi

# --------------------------------------------------------------- preflight --
preflight() {
  local miss=()
  command -v gcc        >/dev/null || miss+=(gcc)
  command -v cyclictest >/dev/null || miss+=(rt-tests)
  perf --version >/dev/null 2>&1   || miss+=(linux-perf)
  command -v htop       >/dev/null || miss+=(htop)
  python3 -c 'import RPi.GPIO' 2>/dev/null || miss+=(python3-rpi-lgpio)
  if [[ ${#miss[@]} -gt 0 ]]; then
    echo "Missing packages: ${miss[*]}"
    read -r -p "Install them now with apt? [Y/n] " a
    if [[ $a != n && $a != N ]]; then
      apt-get update && apt-get install -y "${miss[@]}" || echo "!! apt install failed for some packages — fix by hand."
    fi
  else
    echo "gcc, cyclictest, perf, htop, RPi.GPIO: OK"
  fi
  if [[ -f /usr/local/include/pigpio.h || -f /usr/include/pigpio.h ]] && ldconfig -p | grep -q libpigpio.so; then
    echo "pigpio: OK"
  else
    echo "pigpio is not installed (handout p.9). Commands:"
    echo "  cd /home/$RUN_USER && git clone https://github.com/joan2937/pigpio.git && cd pigpio && make && sudo make install && sudo ldconfig"
    read -r -p "Run them now? [Y/n] " a
    if [[ $a != n && $a != N ]]; then
      ( cd "/home/$RUN_USER" && { [[ -d pigpio ]] || sudo -u "$RUN_USER" git clone https://github.com/joan2937/pigpio.git; } \
        && cd pigpio && sudo -u "$RUN_USER" make && make install && ldconfig ) || echo "!! pigpio install failed — see output above."
    fi
  fi
  # perf needs this to count hardware events as the normal user
  local pp; pp=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "?")
  echo "perf_event_paranoid = $pp  (lab4_auto falls back to root perf if user perf can't read counters)"
  {
    echo "=== week $WEEK checklist evidence  $(date)"
    echo "\$ uname -a"; uname -a
    echo "\$ cat /sys/kernel/realtime"; cat /sys/kernel/realtime 2>/dev/null || echo "(absent)"
    echo "\$ grep kernel= config.txt"; grep -Hn '^kernel=' /boot/firmware/config.txt /boot/config.txt 2>/dev/null || echo "(none)"
    echo "\$ cat /proc/cmdline"; cat /proc/cmdline
  } > "$KIT/results/uname_week${WEEK}_${KTAG}.txt"
  echo "Saved $KIT/results/uname_week${WEEK}_${KTAG}.txt"
  echo
  echo "Before the scope steps: probe on GPIO 13 (physical pin 33), ground clip on a GND pin."
}

report() {
  if command -v python3 >/dev/null; then
    sudo -u "$RUN_USER" python3 "$KIT/lab4_report.py" "$KIT/results" || python3 "$KIT/lab4_report.py" "$KIT/results"
  else
    echo "python3 not found - copy results/ to your laptop and run: python3 lab4_report.py results"
  fi
}

# ------------------------------------------------------------------ runner --
cd "$KIT" || exit 1
show_list; echo
for ((i=1; i<=N; i++)); do
  entry="${STEPS[$((i-1))]}"; title="${entry%%|*}"; cmd="${entry#*|}"
  if [[ -n "$ONLY" ]]; then [[ $i == "$ONLY" ]] || continue
  else
    (( i < FROM )) && continue
    if (( FROM == 1 )) && is_done "$i"; then echo "-- step $i already done, skipping (use --step $i to redo)"; continue; fi
  fi

  echo "=================================================================="
  echo " Week $WEEK  step $i/$N:  $title"
  echo "   command: $cmd"
  echo "=================================================================="
  if [[ $YES -eq 0 ]]; then
    read -r -p " [Enter] run  |  s skip  |  q quit: " a
    case "$a" in q) echo "Stopped. Re-run the same command later to continue."; exit 0 ;; s) continue ;; esac
  fi

  case "$cmd" in
    preflight) preflight; rc=$? ;;
    report)    report;    rc=$? ;;
    *)         eval "$cmd"; rc=$? ;;
  esac
  if [[ $rc -eq 0 ]]; then
    grep -qx "$i" "$STATE" || echo "$i" >> "$STATE"
    echo ">> step $i done"
  else
    echo ">> step $i exited with code $rc - not marked done. Fix and re-run with: sudo bash week${WEEK}.sh --step $i"
    if [[ $YES -eq 0 ]]; then read -r -p "    Continue to the next step anyway? [y/N] " a; [[ $a == y || $a == Y ]] || exit "$rc"; fi
  fi
  chown -R "$RUN_USER":"$RUN_USER" "$KIT/results" 2>/dev/null
done
echo
show_list
echo
echo "Results: $KIT/results   (REPORT.md, ALL_RUNS.csv, ALL_WAVES.csv, per-run folders)"
