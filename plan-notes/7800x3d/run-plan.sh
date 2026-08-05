#!/bin/bash
# Execute a per-box sweep plan against the all-fixes-integration-v4 tree.
#
#   ./run-plan.sh plan-x3d.tsv
#   ./run-plan.sh plan-laptop.tsv
#
# The two plan files are independent: neither box reads the other's output and
# neither waits on the other. Merge the CSVs afterwards if you want the
# cross-box differentials as well (same mode on different hardware must agree).
#
# Resumable. A sweep whose results.csv already has the expected row count is
# skipped, so the script can be interrupted and restarted freely across days.
#
# env:
#   WT       source tree to build            (default: the repo this script lives in)
#            This branch is based on all-fixes-integration-v4 and therefore
#            *contains* the tree under test, so the default is correct on a fresh
#            clone of the branch on any machine. Override only to test elsewhere.
#   OUT      results directory                (default ./results-$(hostname -s))
#   RAM_GB   memory budget                    (default 90% of MemAvailable)
#   JOBS     core count                       (default nproc)
#   ITERS    iterations per run               (default 100)
#   MINK     skip lengths below this many kblocks  (default all)
#   MAXK     skip lengths above this many kblocks  (default all) - for smoke tests
#   DRYRUN   1 = print the schedule and exit

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PLAN=${1:?usage: run-plan.sh <plan.tsv>}
WT=${WT:-$(cd "$HERE/../.." && pwd)}
OUT=${OUT:-$HERE/results-$(hostname -s)}
JOBS=${JOBS:-$(nproc)}
ITERS=${ITERS:-100}
export RAM_GB=${RAM_GB:-$(awk '/MemAvailable/{printf "%d", $2/1048576*0.9}' /proc/meminfo)}
[[ -n ${MINK:-} ]] && export MINK
[[ -n ${MAXK:-} ]] && export MAXK

[[ -f $WT/makemake.sh && -f $WT/src/Mlucas.c ]] || {
    echo "not a Mlucas source tree: $WT" >&2; exit 1; }
WT=$(cd "$WT" && pwd)
mkdir -p "$OUT"

# --- expected row counts, so "already done" is a fact and not a guess ----------
# Honours MINK/MAXK, so a deliberately capped plan (the Pi runs one) stays
# resumable instead of restarting every sweep from scratch.
expected_rows() {
    awk -v mn="${MINK:-1}" -v mx="${MAXK:-524288}" \
        '!/^#/ && $1>=mn && $1<=mx {s+=$2} END{print s+0}' "$HERE/$1"
}

# --- builds -------------------------------------------------------------------
build() { local mode=$1 cc=${2:-gcc} dir
    dir="$WT/obj_${mode}${cc:+_$cc}"
    [[ -x $dir/Mlucas ]] && { echo "$dir/Mlucas"; return 0; }
    ( cd "$WT" && rm -rf "obj_$mode" &&
      CC=$cc bash -e -o pipefail -- ./makemake.sh "$mode" >"$OUT/build_${mode}_${cc}.log" 2>&1 ) || {
        echo "BUILD FAILED $mode/$cc - see $OUT/build_${mode}_${cc}.log" >&2; return 1; }
    [[ $dir != "$WT/obj_$mode" ]] && mv "$WT/obj_$mode" "$dir"
    echo "$dir/Mlucas"
}

# --- schedule -----------------------------------------------------------------
printf '%-34s %-8s %-7s %-7s %-6s\n' TAG MODE THREADS TYPE SHIFT
n=0
while IFS=$'\t' read -r mode threads type shift cc; do
    [[ -z ${mode:-} || $mode == \#* ]] && continue
    printf '%-34s %-8s %-7s %-7s %-6s\n' "${mode}-t${threads}-${type}-s${shift}${cc:+-$cc}" "$mode" "$threads" "$type" "$shift"
    n=$((n+1))
done < "$PLAN"
echo "  $n sweeps in $PLAN"
[[ ${DRYRUN:-0} == 1 ]] && exit 0

# --- run ----------------------------------------------------------------------
start=$(date +%s)
while IFS=$'\t' read -r mode threads type shift cc; do
    [[ -z ${mode:-} || $mode == \#* ]] && continue
    tag="${mode}-t${threads}-${type}-s${shift}${cc:+-$cc}"
    cc=${cc:-gcc}
    wl="worklist_v4_simd.txt"
    [[ $mode == nosimd ]] && wl="worklist_v4_scalar.txt"
    want=$(expected_rows "$wl")

    csv="$OUT/$tag/results.csv"
    if [[ -f $csv ]] && (( want > 0 )) && (( $(grep -c . "$csv") - 1 >= want )); then
        echo "[skip] $tag (complete: $((  $(grep -c . "$csv") - 1 )) rows)"; continue
    fi
    bin=$(build "$mode" "$cc") || continue

    echo "=== $tag  ($(date '+%F %T')) ==="
    BIN="$bin" TAG="$tag" OUT="$OUT" TYPE="$type" THREADS="$threads" \
    SHIFT="$shift" ITERS="$ITERS" JOBS="$JOBS" RAM_GB="$RAM_GB" \
        bash "$HERE/sweep.sh" "$HERE/$wl"
done < "$PLAN"

echo; echo "All sweeps done in $(( ($(date +%s)-start)/3600 ))h. Analysing..."
bash "$HERE/compare.sh" "$OUT"/*/results.csv | tee "$OUT/ANALYSIS.txt"
