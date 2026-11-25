#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 2 ]]; then
    echo "usage: $0 BASELINE_RUN FINAL_RUN" >&2
    exit 2
fi
base=$(cd "$1" && pwd)
final=$(cd "$2" && pwd)
db="$final/coverage.vdb"
out="$final/urg/attribution"
mkdir "$out"
cd "$out"
record() { printf '%q ' "$@" >>commands.sh; printf '\n' >>commands.sh; }

catalog=(urg -full64 -dir "$db" -show availabletests)
record "${catalog[@]}"
timeout 100s "${catalog[@]}" >available-tests.log 2>&1
cp "$base/tests.list" inherited.names
cp "$base/tests.list" responses.names
printf '%s\n' axi4_b2b_slverr_write_test axi4_b2b_slverr_read_test >>responses.names
for stage in inherited responses; do
    while IFS= read -r test; do
        awk -F/ -v name="$test" '/^\// && $NF == name {print; found++}
                                END {if (found != 1) exit 1}' available-tests.log
    done <"$stage.names" >"$stage.list"
    command=(urg -full64 -dir "$db" -tests "$out/$stage.list" -metric group -format both
             -show ratios -show tests -group maxmissing 1000 -group show_bin_values -report "$out/$stage")
    record "${command[@]}"
    timeout 120s "${command[@]}" >"$stage.log" 2>&1
    test -s "$stage/grpinfo.txt"
    count=$(wc -l <"$stage.list")
    grep -qx "Number of tests: $count" "$stage/dashboard.txt"
done
