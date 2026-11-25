#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
src=$1
run=$2
scripts=$(cd "$(dirname "$0")" && pwd)
bench="$scripts/../source/added_tests/axi4_checker_only_top.sv"
mkdir "$run"
mkdir "$run"/{compile,regression,urg,waves}
db="$run/coverage.vdb"
metrics=line+cond+tgl+branch+assert
cp "$scripts/checker_cases.list" "$run/tests.list"
record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }

cd "$run/compile"
record cd "$PWD"
build=(vcs -full64 -sverilog -timescale=1ns/1ps -top top
       "+incdir+$src/axi4/sv/assertions" "+incdir+$src/common/sv"
       "$src/axi4/sv/if/axi4_if.sv" "$bench" -cm "$metrics" -cm_dir "$db"
       -Mdir=csrc -o simv -l compile.log)
record "${build[@]}"
timeout 240s "${build[@]}" >driver.log 2>&1
[[ -x simv && -d "$db" ]]
printf 'COMPILE PASS %s\n' "$run"

cd "$run/regression"
record cd "$PWD"
while IFS= read -r test; do
    [[ $test =~ ^[a-z0-9_]+$ ]]
    args=("$run/compile/simv" -exitstatus -cm "$metrics" -cm_dir "$db" -cm_name "$test"
          +ntb_random_seed=1 +KVIPS_AXI4_ASSERT_KNOWN +KVIPS_WAVES "+SCENARIO=$test")
    record "${args[@]}"
    rc=0
    timeout 30s "${args[@]}" >"$test.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$test.rc"
    if [[ -s kvips_axi4_checker.vcd ]]; then mv kvips_axi4_checker.vcd "$run/waves/$test.vcd"; fi
    printf 'SIM_RC %s %d\n' "$test" "$rc"
    if ! grep -q "^CHECKER_RECOVERY_PASS $test " "$test.log"; then
        tail -18 "$test.log" >&2
        exit 1
    fi
    grep -E '^(CHECKER_RECOVERY_PASS|OVERLAP_COUNTER|KVIPS_AXI4_ASSERT:)' "$test.log"
done <"$run/tests.list" | tee "$run/regression.log"
