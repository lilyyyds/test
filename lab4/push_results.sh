#!/usr/bin/env bash
# push_results.sh - upload Lab 4 results to GitHub (run WITHOUT sudo, after the tests)
#   cd ~/lab4_git/lab4 && bash push_results.sh
# Commits lab4_week1_stock/results and lab4_week2_rt/results (compiled binaries skipped)
# and pushes. GitHub asks for username + a token with "Contents: Read and write".
set -u
cd "$(dirname "$0")" || exit 1
[[ $EUID -eq 0 ]] && { echo "Run without sudo:  bash push_results.sh"; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "Not inside the git clone (~/lab4_git)."; exit 1; }

git config user.name  >/dev/null || git config user.name  "Lily Chenxi Li"
git config user.email >/dev/null || git config user.email "102584182+lilyyyds@users.noreply.github.com"

paths=()
for d in lab4_week1_stock/results lab4_week2_rt/results; do
  [[ -d $d ]] && paths+=("$d")
done
[[ ${#paths[@]} -gt 0 ]] || { echo "No results/ folders yet - run week1.sh / week2.sh first."; exit 1; }

# refresh REPORT.md so it includes both weeks
if [[ -d lab4_week2_rt/results ]]; then
  python3 lab4_week2_rt/lab4_report.py lab4_week2_rt/results >/dev/null 2>&1 || true
elif [[ -d lab4_week1_stock/results ]]; then
  python3 lab4_week1_stock/lab4_report.py lab4_week1_stock/results >/dev/null 2>&1 || true
fi

git add -A "${paths[@]}"
if git diff --cached --quiet; then echo "Nothing new to upload."; exit 0; fi
echo "Uploading:"; git diff --cached --stat | tail -15
git commit -q -m "Lab 4 results: $(uname -r), $(date '+%Y-%m-%d %H:%M')" || exit 1
git pull --rebase -q || { echo "git pull failed - fix the conflict, then run: git push"; exit 1; }
if git push -q; then
  echo "Done: https://github.com/lilyyyds/test/tree/main/lab4"
else
  echo "Push failed. Usually the token is missing or read-only - see lab4/README.md (Uploading results)."
  echo "Your results are committed locally; just run 'git push' again after fixing."
  exit 1
fi
