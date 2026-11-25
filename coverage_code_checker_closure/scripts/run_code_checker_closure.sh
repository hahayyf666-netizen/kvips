#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# != 3 ]]; then
    echo "Usage: $0 {baseline|positive|negative|vip} SOURCE_ROOT NEW_REPORT_DIR" >&2
    exit 2
fi
mode=$1
src=$(cd "$2" && pwd)
run=$(realpath -m "$3")
scripts=$(cd "$(dirname "$0")" && pwd)
fc="$src/coverage_functional_enhancement/scripts"
metrics=line+cond+tgl+branch+assert

record() { printf '%q ' "$@" >>"$run/commands.sh"; printf '\n' >>"$run/commands.sh"; }

report_code() {
    local name=$1 metric=$2
    local -a command=(urg -full64 -dir "$run/coverage.vdb" -metric "$metric"
        -format both -show ratios -show tests -report "$run/urg/$name")
    if [[ $metric != assert ]]; then command+=(-cond ids); fi
    record "${command[@]}"
    timeout 150s "${command[@]}" >"$run/urg/$name.log" 2>&1
    test -s "$run/urg/$name/dashboard.txt"
}

case "$mode" in
    baseline|positive)
        tests="$fc/final_tests.list"
        bash <(sed 's/\r$//' "$fc/run_functional_coverage.sh") "$src" "$run" "$tests"
        if [[ $mode == positive ]]; then
            bash "$scripts/run_new_ram_tests.sh" "$run" "$scripts/positive_tests.list"
        fi
        report_code all "$metrics"
        report_code code line+cond+tgl+branch
        report_code assertions assert
        if [[ $mode == positive ]]; then bash "$scripts/report_test_details.sh" "$mode" "$run"; fi
        ;;
    vip)
        bash <(sed 's/\r$//' "$fc/run_vip_guard.sh") "$src" \
            "$src/axi4/examples/uvm_back2back/sim/tests_questa.list" "$run"
        ;;
    negative)
        bash "$scripts/run_checker_cases.sh" "$src" "$run"
        report_code all "$metrics"
        report_code code line+cond+tgl+branch
        report_code assertions assert
        bash "$scripts/report_test_details.sh" "$mode" "$run"
        ;;
    *)
        echo "Unknown mode $mode" >&2
        exit 2
        ;;
esac
