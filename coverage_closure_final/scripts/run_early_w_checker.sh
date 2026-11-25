#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 3 || ( "$3" != before && "$3" != after ) ]]; then
    echo "usage: $0 SOURCE_ROOT NEW_OUTPUT_DIR before|after" >&2
    exit 2
fi
src=$(cd "$1" && pwd)
scripts=$(cd "$(dirname "$0")" && pwd)
out=$2
mode=$3
mkdir "$out"
cd "$out"
build=(vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
       +define+KVIPS_AXI4_NO_ASSERTIONS
       "+incdir+$src/axi4/sv/uvm" "+incdir+$src/common/sv"
       "$src/axi4/sv/if/axi4_if.sv" "$src/axi4/sv/pkg/axi4_types_pkg.sv"
       "$src/axi4/sv/pkg/axi4_uvm_pkg.sv" "$scripts/early_w_checker_tb.sv"
       -top early_w_checker_top -o simv -l compile.log)
record() { printf '%q ' "$@" >>commands.sh; printf '\n' >>commands.sh; }
record "${build[@]}"
timeout 180s "${build[@]}" >compile-driver.log 2>&1
for variant in legal injected; do
    args=(./simv -exitstatus +ntb_random_seed=1 +UVM_VERBOSITY=UVM_LOW)
    if [[ "$variant" == injected ]]; then args+=(+CLOSURE_BAD_EARLY_WSTRB); fi
    record "${args[@]}"
    rc=0
    timeout 45s "${args[@]}" >"$variant.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$variant.rc"
done
python - "$mode" <<'PY' | tee verdict.log
from __future__ import print_function
import re
import sys

for case in ('legal', 'injected'):
    log = open(case + '.log').read()
    rc = int(open(case + '.rc').read().strip())
    expected = int(case == 'injected' and sys.argv[1] == 'after')
    errors = re.findall(r'^UVM_ERROR[ \t]+(?!:)\S.*$', log, re.M)
    types = re.findall(r'^UVM_(?:ERROR|FATAL)\s*:\s*(\d+)\s*$', log, re.M)
    target = 'WSTRB out of legal lanes: AWID=3 beat=1 AWADDR=1022 SIZE=1 WSTRB=31 allowed=30 illegal=1'
    result = (
        len(errors) == expected
        and (not expected or ('[AXI4_CHK]' in errors[0] and target in errors[0]))
        and types == [str(expected), '0']
        and '[EARLY_W_DONE] bad=%d complete_early=2 partial_early=1 aw_first=1' % (case == 'injected') in log
        and 'AW=4 W=6 B=4 AR=0 R=0 errors=%d sideband_errors=0' % expected in log
        and rc in ((0, 1) if expected else (0,))
        and not re.search(r'^Error-\[|^Fatal:', log, re.M))
    print('%s %s %s SIM_RC=%d checker_errors=%d' %
          ('PASS' if result else 'FAIL', sys.argv[1], case, rc, len(errors)))
    if not result:
        sys.exit(1)
PY
