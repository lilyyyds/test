#!/usr/bin/env bash
# =============================================================================
# week1_noscope.sh  —  Lab 4 Week 1 tests that need NO oscilloscope (stock kernel)
#
#   sudo bash week1_noscope.sh            tool check -> perf + cyclictest (~30 min) -> REPORT.md
#   sudo bash week1_noscope.sh --quick    2-min pipeline check only (not lab data)
#   sudo bash week1_noscope.sh --load 8   use 8 sort_v1 copies instead of 20 (if the Pi rebooted)
#
# Runs steps 1, 2 and 5 of week1.sh without pausing. Finished steps are remembered,
# so when you have a scope later, 'sudo bash week1.sh' only does the scope steps.
# =============================================================================
D="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo bash $0 $*"; exit 1; }

if [[ "${1:-}" == "--quick" ]]; then
  exec bash "$D/lab4_auto.sh" --quick
fi

echo ">>> Week 1, no-scope tests on: $(uname -r)   (expected: stock kernel)"
bash "$D/lab4_week.sh" 1 --step 1 --yes "$@" || exit $?
bash "$D/lab4_week.sh" 1 --step 2 --yes "$@" || exit $?
bash "$D/lab4_week.sh" 1 --step 5 --yes "$@"
echo
echo ">>> Finished. Report: $D/results/REPORT.md"
echo ">>> Upload to GitHub (no sudo):  cd $(dirname "$D") && bash push_results.sh"
