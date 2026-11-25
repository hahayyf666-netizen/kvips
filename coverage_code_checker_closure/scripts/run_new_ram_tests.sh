#!/usr/bin/env bash
set -euo pipefail
run=$(cd "$1" && pwd)
tests=$2
metrics=line+cond+tgl+branch+assert
record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }

cd "$run/regression"
record cd "$PWD"
while IFS= read -r test; do
    [[ $test == axi4_dut_*_test ]]
    args=("$run/compile/simv" -exitstatus -cm "$metrics" -cm_dir "$run/coverage.vdb" -cm_name "$test"
          +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW +UVM_TIMEOUT=10000,NO +KVIPS_AXI4_COV=1
          +DUT_FCOV_EXT=1 +DUT_FCOV_TRACE +KVIPS_WAVES +KVIPS_AXI4_ASSERT_KNOWN "+UVM_TESTNAME=$test")
    if [[ $test == axi4_dut_idle_rready_test ]]; then args+=(+DUT_DEBUG); fi
    record "${args[@]}"
    rc=0
    timeout 100s "${args[@]}" >"$test.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$test.rc"
    if [[ -s kvips_axi4_dut.vcd ]]; then mv kvips_axi4_dut.vcd "$run/waves/$test.vcd"; fi
    printf 'SIM_RC %s %d\n' "$test" "$rc"
    if [[ $rc != 0 ]] || ! grep -qx "CODE_SCENARIO_PASS $test" "$test.log" ||
        ! grep -Eq '^UVM_ERROR[[:space:]]*:[[:space:]]*0$' "$test.log" ||
        ! grep -Eq '^UVM_FATAL[[:space:]]*:[[:space:]]*0$' "$test.log" ||
        grep -Eiq '^Error[-:]|^Fatal:|a_kvips_.*failed at|KVIPS_AXI4_ASSERT:' "$test.log"; then
        tail -22 "$test.log" >&2
        exit 1
    fi
    grep -E '^RESET_CONTEXT|^CODE_SCOREBOARD|^CODE_SCENARIO_PASS' "$test.log"
done <"$tests" | tee "$run/new-tests.log"
cp "$tests" "$run/additional-tests.list"

cd "$run"
record cd "$PWD"
args=(urg -full64 -dir "$run/coverage.vdb" -metric group -format both -show ratios -show tests
      -group maxmissing 1000 -group show_bin_values -report "$run/urg/functional_all")
record "${args[@]}"
timeout 150s "${args[@]}" >"$run/urg/functional_all.log" 2>&1
test -s "$run/urg/functional_all/grpinfo.txt"
