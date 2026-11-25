#!/bin/bash
set -u
stage=$1
bash "$stage/scripts/run_coverage_closure.sh" "$stage/source/baseline" "$stage/reports/baseline"
status=$?
printf '%s\n' "$status" > "$stage/logs/baseline.exit"
if [[ -x "$stage/reports/baseline/compile/simv" ]]; then
 (
  cd "$stage/source/baseline" || exit 2
  env -u KVIPS_REUSE_BUILD timeout 180s bash axi4/examples/uvm_dut/sim/run_vcs.sh \
    +UVM_TESTNAME=axi4_dut_addr_ref_test +ADDR_REF_ITERS=1000 +ADDR_REF_SEED=1 \
    +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW
 ) > "$stage/METHOD_EVIDENCE/functional_coverage/addr_ref_runner.log" 2>&1
 printf '%s\n' "$?" > "$stage/METHOD_EVIDENCE/functional_coverage/addr_ref.exit"
fi
date -Is > "$stage/logs/baseline.done"
