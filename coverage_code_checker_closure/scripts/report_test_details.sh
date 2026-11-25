#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
mode=$1
run=$(cd "$2" && pwd)
out="$run/urg/by_test"
metrics=line+cond+tgl+branch+assert
mkdir "$out"
cd "$out"
record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }
record cd "$PWD"
cmd=(urg -full64 -dir "$run/coverage.vdb" -show availabletests)
record "${cmd[@]}"
timeout 90s "${cmd[@]}" >available-tests.log 2>&1

select_tests() {
    for test in "$@"; do
        awk -F/ -v t="$test" '/^\// && $NF == t {print; n++} END {if (n != 1) exit 1}' available-tests.log
    done
}

report_subset() {
    local name=$1
    shift
    select_tests "$@" >"$name.list"
    local -a cmd=(urg -full64 -dir "$run/coverage.vdb" -tests "$out/$name.list" -metric "$metrics"
        -format both -show ratios -show tests -cond ids -report "$out/$name")
    record "${cmd[@]}"
    timeout 120s "${cmd[@]}" >"$name.log" 2>&1
    grep -qx "Number of tests: $#" "$name/dashboard.txt"
}

if [[ $mode == positive ]]; then
    mapfile -t legacy <"$run/tests.list"
    report_subset legacy_30 "${legacy[@]}"
    cases="$run/additional-tests.list"
else
    mapfile -t cases_all <"$run/tests.list"
    report_subset required_faults "${cases_all[@]:0:11}"
    cases="$run/tests.list"
fi
while IFS= read -r test; do
    report_subset "$test" "$test"
done <"$cases"
