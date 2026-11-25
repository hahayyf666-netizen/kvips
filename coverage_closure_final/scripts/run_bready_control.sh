#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "usage: $0 FINAL_RUN NEW_CONTROL_DIR" >&2
    exit 2
fi
run=$(cd "$1" && pwd)
mkdir "$2"
cd "$2"
metrics=line+cond+tgl+branch+assert
# VCS may require the instrumented design database in the alternate directory.
cp -a "$run/coverage.vdb" control.vdb
args=("$run/compile/simv" -exitstatus -cm "$metrics" -cm_dir "$PWD/control.vdb"
      -cm_name closure_bready_control +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW
      +KVIPS_AXI4_COV=1 +UVM_TESTNAME=axi4_dut_closure_bready_test
      +DUT_DEBUG +KVIPS_WAVES +KVIPS_AXI4_ASSERT_KNOWN +CLOSURE_BREADY_CONTROL)
printf '%q ' "${args[@]}" >commands.sh; printf '\n' >>commands.sh
rc=0
timeout 80s "${args[@]}" >control.log 2>&1 || rc=$?
printf '%s\n' "$rc" >control.rc
test "$rc" = 0
grep -Eq '^UVM_ERROR +: +0 *$' control.log
grep -Eq '^UVM_FATAL +: +0 *$' control.log
grep -Eq 'AW=64 W=256 B=64 AR=64 R=256 errors=0 sideband_errors=0' control.log
grep -q 'wr_txns=64 wr_err=0 rd_txns=64 rd_mismatch_beats=0 rd_uninit_warn_beats=0' control.log
grep -q '\[CLOSURE_B_SUMMARY\].*b_handshakes=64.*hold_errors=0' control.log
grep -E '^\s*UVM_INFO.*\[CLOSURE_B_SUMMARY\]' control.log >verdict.log
