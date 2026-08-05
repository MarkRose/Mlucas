#!/bin/bash
# Exhaustive (FFT length x radix set) sweep for one configuration.
#
# Emits one CSV row per run so that runs from different configurations can be
# diffed against each other by compare.sh. The comparison is the point: we have
# no reference residues for 603 radix sets, but every radix set at a given
# (length, exponent, type, shift) MUST agree, and every build mode and thread
# count must agree too. Disagreement is a bug with no judgement call required.
#
# usage: BIN=... TAG=... [opts] ./sweep.sh <worklist>
#
#   BIN      path to the Mlucas binary                      (required)
#   TAG      label for this configuration, e.g. avx512-gcc16-t1-ll-s0   (required)
#   OUT      output directory                               (default ./results)
#   TYPE     ll | prp | fermat                              (default ll)
#   THREADS  worker threads, or "auto" for size-tiered        (default 1)
#   SHIFT    0 | nz | <integer> | none                       (default 0)
#            "nz" = a FIXED nonzero shift (12345). It must be fixed, not random:
#            Mlucas.c:1657 loops while(!itmp64) so an omitted -shift gives a
#            random nonzero shift, which would differ per run and manufacture
#            cross-config mismatches. 12345 < 42443, the smallest exponent in
#            the v4 worklists, so it is legal at every length.
#            "none" omits -shift entirely (random) - never use it for sweeps.
#   ITERS    iterations per run                             (default 100)
#   MINK     skip lengths below this many kblocks           (default 1)
#   MAXK     skip lengths above this many kblocks           (default 524288)
#   JOBS     max concurrent jobs for the smallest tier      (default nproc)
#   TIMEOUT  per-run timeout in seconds                     (default 3600)
#   RAM_GB   memory budget for concurrency (default: 90% of MemAvailable)
#
# Fermat notes: fermat_mod_square.c:332 requires n/radix0 to be a power of two,
# so most (length, radset) pairs are simply not Fermat-legal. The binary rejects
# them itself; those rows are recorded as skipped, not as failures.

set -u

WORKLIST=${1:?usage: sweep.sh <worklist>}
BIN=${BIN:?set BIN to the Mlucas binary}
TAG=${TAG:?set TAG to a configuration label}
OUT=${OUT:-./results}
TYPE=${TYPE:-ll}
THREADS=${THREADS:-1}
SHIFT=${SHIFT:-0}
ITERS=${ITERS:-100}
MINK=${MINK:-1}
MAXK=${MAXK:-524288}
JOBS=${JOBS:-$(nproc)}
TIMEOUT=${TIMEOUT:-3600}

[[ -x $BIN ]] || { echo "BIN not executable: $BIN" >&2; exit 1; }
BIN=$(realpath "$BIN")
mkdir -p "$OUT/$TAG/logs"
CSV="$OUT/$TAG/results.csv"
echo "tag,type,mode_threads,shift,kblocks,radset,exponent,res64,maxerr,avgmaxerr,radices,rc,seconds,status" > "$CSV"

# One run. Called via xargs; everything it needs comes through the environment.
run_one() {
    local k=$1 rs=$2 p=$3
    local log="$OUT/$TAG/logs/${k}K_rs${rs}.log"
    local -a args=(-fftlen "$k" -radset "$rs" -iters "$ITERS")

    case $TYPE in
        ll)     args+=(-m "$p") ;;
        prp)    args+=(-m "$p" -prp) ;;
        # Fermat index is fixed by the FFT length, not chosen: F_findex needs
        # n >= 2^findex/64 bits. Derive the largest index this length supports.
        fermat) local f; f=$(awk -v k="$k" 'BEGIN{n=k*1024; print int(log(n*64)/log(2))-1}')
                args+=(-f "$f") ;;
    esac
    local sh=$SHIFT
    [[ $sh == nz ]] && sh=12345
    [[ $sh != none ]] && args+=(-shift "$sh")
    local t=$THREADS
    [[ $THREADS == auto ]] && t=$(auto_threads "$k")
    if (( t > 1 )); then args+=(-cpu "0:$((t-1))"); else args+=(-cpu 0); fi

    local t0 t1 rc
    t0=$(date +%s.%N)
    timeout "$TIMEOUT" "$BIN" "${args[@]}" > "$log" 2>&1; rc=$?
    t1=$(date +%s.%N)

    local res err avg rad secs status
    res=$(grep -oE 'Res64: [0-9A-F]{16}' "$log" | head -1 | cut -d' ' -f2)
    err=$(grep -oE 'MaxErr = [0-9.]+' "$log" | tail -1 | cut -d' ' -f3)
    avg=$(grep -oE 'AvgMaxErr = [0-9.]+' "$log" | tail -1 | cut -d' ' -f3)
    rad=$(grep -oE 'Using complex FFT radices.*' "$log" | head -1 | sed 's/Using complex FFT radices *//;s/  */-/g')
    secs=$(echo "$t1 - $t0" | bc)

    # Classify. "skip" is a legitimate not-applicable, distinct from a failure.
    if   grep -qiE 'Skipping this radix combo|radix set.*unavailable|ERR_RADIXSET' "$log"; then status=skip
    elif grep -qiE 'not a power of 2|does not divide N' "$log";                            then status=skip-fermat
    elif [[ -z $res ]] && (( rc != 0 ));                                                   then status=fail
    elif [[ -z $res ]];                                                                    then status=nores
    elif grep -qiE "Assertion .* failed|nonzero exit carry|ERROR ERROR"  "$log";           then status=abort
    elif grep -qiE 'Roundoff warning' "$log";                                              then status=roe
    else status=ok
    fi
    # Keep logs only for anything that isn't a clean pass; a full sweep is 603 logs
    # per config and the successful ones are never read.
    [[ $status == ok ]] && rm -f "$log"

    printf '%s,%s,%s/%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%s\n' \
        "$TAG" "$TYPE" "$(basename "$(dirname "$BIN")")" "$t" "$SHIFT" \
        "$k" "$rs" "$p" "${res:-NONE}" "${err:-NA}" "${avg:-NA}" "${rad:-NA}" \
        "$rc" "$secs" "$status" >> "$CSV"
}
# THREADS=auto: above ~128M these FFTs are memory-bandwidth bound, so extra
# *concurrent jobs* buy almost nothing while costing 4.4x the array each in RAM.
# Measured on the i9 at 256M: one job with 8 threads = 1.90x, and 8 threads at 64M
# = 3.15x while 4 concurrent 1-thread jobs = 3.00x - i.e. threads and jobs hit the
# same wall. Threads win at the top end on three counts: one-third the memory,
# each result lands sooner, and multithreaded large-FFT runs exercise the
# carry-thread paths where #207 and #152 lived. Deterministic, so cross-config
# comparison stays apples-to-apples as long as every config uses the same policy.
auto_threads() { local k=$1 t
    if   (( k <=  65536 )); then t=1
    elif (( k <= 262144 )); then t=4
    else                         t=8
    fi
    # Never oversubscribe: a 4-core Pi must not be handed 8 threads.
    (( t > JOBS )) && t=$JOBS
    echo "$t"
}
export -f run_one auto_threads
export BIN TAG OUT TYPE THREADS SHIFT ITERS TIMEOUT CSV JOBS

# Expand the worklist into (kblocks, radset, exponent) triples, bucketed by size.
#
# Memory-aware. Measured on 2026-08-05: peak RSS is ~4.4x the main array, and the
# main array is kblocks*8 KB. (4.4x is measured, not assumed - at 64M the array is
# 512 MB and peak RSS is 2232 MB.) So a 512M run needs ~17.6 GB, and RAM_GB is the
# real constraint above ~128M; below that it is core count.
RAM_GB=${RAM_GB:-$(awk '/MemAvailable/{printf "%d", $2/1048576*0.9}' /proc/meminfo)}
tier_jobs() { local k=$1 perjob n
    perjob=$(awk -v k="$k" 'BEGIN{printf "%.4f", 4.4*k*8/1048576}')   # GB per job: 4.4x a k*8 KB array
    n=$(awk -v r="$RAM_GB" -v p="$perjob" 'BEGIN{n=int(r/p); print (n<1?1:n)}')
    local per=1
    [[ $THREADS == auto ]] && per=$(auto_threads "$k")
    [[ $THREADS != auto ]] && per=$THREADS
    local bycore=$(( JOBS / per )); (( bycore < 1 )) && bycore=1
    (( n > bycore )) && n=$bycore
    echo "$n"
}

total=0
for tier in "1 8192" "8193 32768" "32769 131072" "131073 262144" "262145 524288"; do
    read -r lo hi <<< "$tier"
    (( lo > MAXK || hi < MINK )) && continue
    P=$(tier_jobs "$hi")
    mapfile -t rows < <(awk -v lo="$lo" -v hi="$hi" -v mn="$MINK" -v mx="$MAXK" \
        '!/^#/ && $1>=lo && $1<=hi && $1>=mn && $1<=mx {for(r=0;r<$2;r++) print $1, r, $4}' "$WORKLIST")
    (( ${#rows[@]} == 0 )) && continue
    echo "[$TAG] tier ${lo}-${hi}K: ${#rows[@]} runs at -P $P"
    printf '%s\n' "${rows[@]}" | xargs -P "$P" -L1 bash -c 'run_one "$@"' _
    total=$(( total + ${#rows[@]} ))
done

echo "[$TAG] $total runs -> $CSV"
awk -F, 'NR>1{c[$NF]++} END{for(s in c) printf "  %-12s %d\n", s, c[s]}' "$CSV"
