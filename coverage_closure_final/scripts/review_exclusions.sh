#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 4 ]]; then
    echo "usage: $0 BASELINE_RUN FINAL_RUN HISTORICAL_EXCLUSIONS NEW_REPORT_DIR" >&2
    exit 2
fi
base=$(cd "$1" && pwd)
final=$(cd "$2" && pwd)
hist=$(cd "$3" && pwd)
mkdir "$4"
cd "$4"
out=$PWD
for stage in baseline final; do
    case "$stage" in
        baseline) run=$base;;
        final) run=$final;;
    esac
    for label in resp wready; do
        case "$label" in
            resp) metric=group; rule="$hist/ram_dut_scope_v3.el";;
            wready) metric=cond; rule="$hist/wready_unreachable.el";;
        esac
        report="$out/$stage-$label"
        cmd=(urg -full64 -dir "$run/coverage.vdb" -metric "$metric" -format both -show ratios
             -elfile "$rule" -excl_strict -report "$report")
        if [[ "$metric" == cond ]]; then
            cmd+=(-cond ids)
        else
            cmd+=(-group maxmissing 1000 -group show_bin_values)
        fi
        printf '%q ' "${cmd[@]}" >>commands.sh; printf '\n' >>commands.sh
        rc=0
        timeout 100s "${cmd[@]}" >"$report.log" 2>&1 || rc=$?
        printf '%s %s\n' "$stage-$label" "$rc" | tee -a exit_status.txt
    done
done
