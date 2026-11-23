#!/usr/bin/env bash
# =============================================================================
# week2_noscope.sh  —  Lab 4 Week 2 tests that need NO oscilloscope (PREEMPT_RT kernel)
#
#   sudo bash week2_noscope.sh            tool check -> perf + cyclictest (~30 min) -> REPORT.md
#   sudo bash week2_noscope.sh --quick    2-min pipeline check only (not lab data)
#   sudo bash week2_noscope.sh --load 8   use 8 sort_v1 copies instead of 20 (if the Pi rebooted)
#
# Runs steps 1, 2 and 7 of week2.sh without pausing. Finished steps are remembered,
# so when you have a scope later, 'sudo bash week2.sh' only does the scope steps.
# =============================================================================
D="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo bash $0 $*"; exit 1; }

if [[ "${1:-}" == "--quick" ]]; then
  exec bash "$D/lab4_auto.sh" --quick
fi

echo ">>> Week 2, no-scope tests on: $(uname -r)   (expected: PREEMPT_RT kernel)"
bash "$D/lab4_week.sh" 2 --step 1 --yes "$@" || exit $?
bash "$D/lab4_week.sh" 2 --step 2 --yes "$@" || exit $?
bash "$D/lab4_week.sh" 2 --step 7 --yes "$@"
echo
echo ">>> Finished. Report: $D/results/REPORT.md"
echo ">>> Upload to GitHub (no sudo):  cd $(dirname "$D") && bash push_results.sh"
