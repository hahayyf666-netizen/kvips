#!/bin/bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s SOURCE_ROOT NEW_RUN_DIR [EXTRA_TESTS_LIST]\n' "$0" >&2
    exit 2
fi
src=$(cd "$1" && pwd)
run=$2
extra=${3:-}
[[ ! -e "$run" ]] || { printf 'Run directory already exists: %s\n' "$run" >&2; exit 2; }
mkdir -p "$run"/{compile,regression,urg}
run=$(cd "$run" && pwd)
sim_rel=axi4/examples/uvm_dut/sim
[[ -f "$src/$sim_rel/filelist.f" ]] || exit 2
command -v vcs >/dev/null
command -v urg >/dev/null
command -v python >/dev/null
scripts=$(cd "$(dirname "$0")" && pwd)
metrics=line+cond+tgl+branch+assert
db="$run/coverage.vdb"

awk 'NF && $1 !~ /^#/ {print $1}' "$src/$sim_rel/tests_questa.list" > "$run/tests.list"
cat >> "$run/tests.list" <<'TESTS'
axi4_dut_burst_size_cross_test
axi4_dut_len_256_test
axi4_dut_sideband_coverage_test
axi4_dut_lock_coverage_test
axi4_dut_unaligned_incr_e2e_test
axi4_dut_id_width_test
TESTS
if [[ -n "$extra" ]]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$extra" >> "$run/tests.list"
fi
if grep -qvE '^axi4_dut_[a-z0-9_]+_test$' "$run/tests.list" ||
   grep -qE 'negative|missing_wlast|premature_wlast|addr_ref' "$run/tests.list" ||
   [[ -n "$(sort "$run/tests.list" | uniq -d)" ]]; then
    printf 'Unexpected, duplicate, or non-normal test in test list\n' >&2
    exit 2
fi

while IFS= read -r entry || [[ -n "$entry" ]]; do
    case "$entry" in
        ''|\#*) printf '%s\n' "$entry";;
        +incdir+/*|/*|+*|-*)
            if [[ "$entry" == +incdir+* && "$entry" != +incdir+/* ]]; then
                printf '+incdir+%s/%s\n' "$src" "${entry#+incdir+}"
            else
                printf '%s\n' "$entry"
            fi
            ;;
        *) printf '%s/%s\n' "$src" "$entry";;
    esac
done < "$src/$sim_rel/filelist.f" > "$run/compile/filelist.abs.f"

record() { printf '%q ' "$@" >> "$run/commands.sh"; printf '\n' >> "$run/commands.sh"; }
record cd "$run/compile"
cd "$run/compile"
build=(vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2
       -f "$run/compile/filelist.abs.f" -cm "$metrics" -cm_dir "$db"
       -Mdir=csrc -o simv -l compile.log)
record "${build[@]}"
timeout 240s "${build[@]}" > driver.log 2>&1
[[ -x "$run/compile/simv" && -d "$db" ]]
printf 'COMPILE PASS %s\n' "$run"

cd "$run/regression"
record cd "$run/regression"
while IFS= read -r test; do
    args=("$run/compile/simv" -exitstatus -cm "$metrics" -cm_dir "$db"
          -cm_name "$test" +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW +KVIPS_AXI4_COV=1
          "+UVM_TESTNAME=$test")
    if [[ "$test" == axi4_dut_closure_bready_test ]]; then
        args+=(+DUT_DEBUG +KVIPS_WAVES +KVIPS_AXI4_ASSERT_KNOWN)
    fi
    record "${args[@]}"
    rc=0
    timeout 80s "${args[@]}" > "$test.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$test.rc"
    grep -E 'Running test|AXI4_CHK.*AW=|AXI4 SB summary:|UVM_ERROR[[:space:]]*:|UVM_FATAL[[:space:]]*:' "$test.log" | tail -n 8 || :
    printf 'SIM_RC %s %s\n' "$test" "$rc"
done < "$run/tests.list" | tee "$run/regression.log"

cd "$run"
record cd "$run"
urg_args=(urg -full64 -dir "$db" -format both -show ratios -show tests -cond ids
          -group maxmissing 1000 -group show_bin_values -report "$run/urg/raw")
record "${urg_args[@]}"
timeout 180s "${urg_args[@]}" > "$run/urg/urg.log" 2>&1
[[ -s "$run/urg/raw/dashboard.txt" && -s "$run/urg/raw/modinfo.txt" ]]
printf 'URG REPORT %s\n' "$run/urg/raw/dashboard.txt"

# Code and functional coverage are reported only for the positive VDB above.
# Run the pure algorithm test through the stock non-coverage runner in a
# different, empty source tree when the outer driver requests it.
python "$scripts/summarize_regression.py" "$run" | tee "$run/regression-verdict.log"
