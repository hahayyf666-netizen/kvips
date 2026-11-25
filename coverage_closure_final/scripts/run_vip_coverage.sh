#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# != 3 ]]; then
    echo "usage: $0 SOURCE_ROOT TEST_LIST NEW_RUN_DIR" >&2
    exit 2
fi
src=$(cd "$1" && pwd)
selected=$(realpath "$2")
run=$3
sim=axi4/examples/uvm_back2back/sim
mkdir "$run"
run=$(cd "$run" && pwd)
mkdir "$run"/{build,tests,urg}
db="$run/coverage.vdb"
metrics=line+cond+tgl+branch+assert

awk '{sub(/\r$/, "")} NF && $1 !~ /^#/ {print $1}' "$selected" >"$run/tests.list"
if [[ ! -s "$run/tests.list" || -n "$(sort "$run/tests.list" | uniq -d)" ]] ||
   grep -qvE '^axi4_b2b(_[a-z0-9_]+)?_test$' "$run/tests.list"; then
    echo "Empty, repeated or invalid test in $selected" >&2
    exit 2
fi
awk -v root="$src" '
    {sub(/\r$/, "")}
    /^\+incdir\+[^/]/ {print "+incdir+" root "/" substr($0,9); next}
    /^[+/#-]/ || /^$/ {print; next}
    {print root "/" $0}
' "$src/$sim/filelist.f" >"$run/build/filelist.abs.f"

record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }
cd "$run/build"
record cd "$PWD"
command=(vcs -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2
         -f "$run/build/filelist.abs.f" -cm "$metrics" -cm_dir "$db" -Mdir=csrc
         -o simv -l compile.log)
record "${command[@]}"
timeout 240s "${command[@]}" >compile-driver.log 2>&1
[[ -x simv && -d "$db" ]]
printf 'COMPILE PASS %s\n' "$run"

cd "$run/tests"
record cd "$PWD"
while IFS= read -r test; do
    command=("$run/build/simv" -exitstatus -cm "$metrics" -cm_dir "$db" -cm_name "$test"
             +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW +VIP_COV +VIP_STATS "+UVM_TESTNAME=$test")
    case "$test" in
        axi4_b2b_exclusive_basic_test|axi4_b2b_exclusive_fail_test|axi4_b2b_error_rate_test|\
        axi4_b2b_slverr_*|axi4_b2b_sideband_coverage_test)
            command+=(+KVIPS_AXI4_TRACE +KVIPS_WAVES)
            ;;
        axi4_b2b_exclusive*|axi4_b2b_*error*)
            command+=(+KVIPS_AXI4_TRACE)
            ;;
    esac
    record "${command[@]}"
    rc=0
    timeout 90s "${command[@]}" >"$test.log" 2>&1 || rc=$?
    if [[ -s kvips_axi4_b2b.vcd ]]; then
        mv kvips_axi4_b2b.vcd "$test.vcd"
    fi
    printf '%s\n' "$rc" >"$test.rc"
    printf 'SIM_RC %s %d\n' "$test" "$rc"
    grep -E 'AXI4_CHK.*AW=|AXI4 SB summary:|^UVM_ERROR +:|^UVM_FATAL +:' "$test.log" || :
done <"$run/tests.list" | tee "$run/regression.log"

cd "$run"
record cd "$PWD"
command=(urg -full64 -dir "$db" -metric group -format both -show ratios -show tests
         -group maxmissing 1000 -group show_bin_values -report "$run/urg/functional")
record "${command[@]}"
timeout 150s "${command[@]}" >"$run/urg/functional.log" 2>&1
test -s "$run/urg/functional/grpinfo.txt"
command=(urg -full64 -dir "$db" -metric assert -format both -show ratios -show tests
         -report "$run/urg/assertions")
record "${command[@]}"
timeout 150s "${command[@]}" >"$run/urg/assertions.log" 2>&1
test -s "$run/urg/assertions/asserts.txt"
