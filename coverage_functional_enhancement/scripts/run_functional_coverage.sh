#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 SOURCE_ROOT NEW_RUN_DIR [EXTRA_TEST_LIST]" >&2
    exit 2
fi
src=$(cd "$1" && pwd)
run=$2
extra=${3:-}
sim=axi4/examples/uvm_dut/sim
mkdir "$run"
run=$(cd "$run" && pwd)
mkdir "$run"/{compile,regression,urg,waves}

db="$run/coverage.vdb"
metrics=line+cond+tgl+branch+assert
awk '{sub(/\r$/, "")} NF && $1 !~ /^#/ {print $1}' "$src/$sim/tests_questa.list" >"$run/tests.list"
cat >>"$run/tests.list" <<'TESTS'
axi4_dut_burst_size_cross_test
axi4_dut_len_256_test
axi4_dut_sideband_coverage_test
axi4_dut_lock_coverage_test
axi4_dut_unaligned_incr_e2e_test
axi4_dut_id_width_test
axi4_dut_closure_toggle_test
axi4_dut_closure_random_test
axi4_dut_closure_bready_test
TESTS
if [[ -n "$extra" ]]; then
    awk '{sub(/\r$/, "")} NF && $1 !~ /^#/ {print $1}' "$extra" >>"$run/tests.list"
fi
if [[ -n "$(sort "$run/tests.list" | uniq -d)" ]] ||
    grep -qvE '^axi4_dut_[a-z0-9_]+_test$' "$run/tests.list" ||
    grep -qE 'negative|missing_wlast|premature_wlast|addr_ref' "$run/tests.list"; then
    echo "Unexpected or repeated test" >&2
    exit 2
fi
awk -v root="$src" '
    {sub(/\r$/, "")}
    /^\+incdir\+[^/]/ {print "+incdir+" root "/" substr($0,9); next}
    /^[+/#-]/ || /^$/ {print; next}
    {print root "/" $0}
' "$src/$sim/filelist.f" >"$run/compile/filelist.abs.f"
sha256sum "$src/axi4/examples/uvm_dut/tb/axi4_dut_func_cov.svh" >"$run/model.sha256"

record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }
cd "$run/compile"
record cd "$PWD"
build=(vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2
       -f "$run/compile/filelist.abs.f" -cm "$metrics" -cm_dir "$db" -Mdir=csrc
       -o simv -l compile.log)
record "${build[@]}"
timeout 240s "${build[@]}" >driver.log 2>&1
[[ -x simv && -d "$db" ]]
printf 'COMPILE PASS %s\n' "$run"

cd "$run/regression"
record cd "$PWD"
while IFS= read -r test; do
    args=("$run/compile/simv" -exitstatus -cm "$metrics" -cm_dir "$db" -cm_name "$test"
          +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW +KVIPS_AXI4_COV=1
          +DUT_FCOV_EXT=1 +DUT_FCOV_TRACE "+UVM_TESTNAME=$test")
    case "$test" in
        axi4_dut_fc_*) args+=(+KVIPS_WAVES +KVIPS_AXI4_ASSERT_KNOWN);;
        axi4_dut_closure_bready_test) args+=(+DUT_DEBUG +KVIPS_WAVES +KVIPS_AXI4_ASSERT_KNOWN);;
    esac
    record "${args[@]}"
    rc=0
    timeout 100s "${args[@]}" >"$test.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$test.rc"
    if [[ -s kvips_axi4_dut.vcd ]]; then
        mv kvips_axi4_dut.vcd "$run/waves/$test.vcd"
    fi
    grep -E 'AXI4_CHK.*AW=|AXI4 SB summary:|^UVM_ERROR +:|^UVM_FATAL +:|\[FCOV_SUMMARY\]' "$test.log" || :
    printf 'SIM_RC %s %s\n' "$test" "$rc"
done <"$run/tests.list" | tee "$run/regression.log"

cd "$run"
record cd "$PWD"
args=(urg -full64 -dir "$db" -metric group -format both -show ratios -show tests
      -group maxmissing 1000 -group show_bin_values -report "$run/urg/functional")
record "${args[@]}"
timeout 150s "${args[@]}" >"$run/urg/functional.log" 2>&1
test -s "$run/urg/functional/grpinfo.txt"
python "$src/coverage_closure_final/scripts/summarize_regression.py" "$run" | tee "$run/regression-verdict.log"
