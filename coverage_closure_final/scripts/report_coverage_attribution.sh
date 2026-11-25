#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 2 ]]; then
    echo "usage: $0 BASELINE_RUN FINAL_RUN" >&2
    exit 2
fi
base=$(cd "$1" && pwd)
final=$(cd "$2" && pwd)
out="$final/urg/attribution"
mkdir "$out"
cd "$out"
record() { printf '%q ' "$@" >>commands.sh; printf '\n' >>commands.sh; }

list=(urg -full64 -dir "$final/coverage.vdb" -show availabletests)
record "${list[@]}"
timeout 100s "${list[@]}" >available-tests.log 2>&1
for n in 0 1 2; do
    ntest=$(($(wc -l <"$base/tests.list") + n))
    stage=stage_"$n"
    head -n "$ntest" "$final/tests.list" | while IFS= read -r test; do
        awk -F/ -v name="$test" '/^\// && $NF == name {print; found++}
                                END {if (found != 1) exit 1}' available-tests.log
    done >"$stage.list"
    cmd=(urg -full64 -dir "$final/coverage.vdb" -tests "$out/$stage.list"
         -format both -show ratios -show tests -cond ids
         -group maxmissing 1000 -group show_bin_values -report "$out/$stage")
    record "${cmd[@]}"
    timeout 135s "${cmd[@]}" >"$stage.log" 2>&1
    grep -q "Number of tests: $ntest$" "$stage/dashboard.txt"
done
# The combined report contains all tests. The code-only score uses the same denominator and scope.
code=(urg -full64 -dir "$final/coverage.vdb" -metric line+cond+tgl+branch
      -format both -show ratios -cond ids -report "$final/urg/code")
record "${code[@]}"
timeout 135s "${code[@]}" >"$final/urg/code.log" 2>&1
