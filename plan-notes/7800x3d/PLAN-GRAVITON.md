# Plan D — AWS Graviton (aarch64)

This is the **primary ARM plan**: the full uncapped ASIMD matrix over all 598 radix
sets. Plan C on the Raspberry Pi is a confirmation subset on second silicon, not a
substitute for this.

Runs independently of every other plan.

```bash
sudo apt install -y gcc clang libhwloc-dev libgmp-dev bc git
git clone -b v4-test-plan git@github.com:MarkRose/Mlucas.git
cd Mlucas/plan-notes/7800x3d
./run-plan.sh plan-graviton.tsv        # no cap; resumable
```

## Why Graviton and not just the Pi

The reason we wanted ARM hardware at all was the **memory model** — ARMv8 is weakly
ordered where x86 is TSO, so a race that is benign in practice on x86 can become
observable on ARM. Graviton is real ARM silicon, so that argument survives intact, and
it is in fact *stronger* here than on the Pi:

- Neoverse V1/V2 are far more aggressively out-of-order than Cortex-A72.
- 16–64 cores contending on shared state is a much better race detector than 4. The
  two race-shaped defects in this campaign, #161 (threadpool drain) and #45
  (thread-local pointer staleness), are precisely what this exercises.

And it runs the same code: **Mlucas has no SVE path.** ASIMD/NEON 128-bit is the only
ARM SIMD, and `USE_ARM_V8_SIMD` simply defines `USE_SSE2` (`platform.h:222`), so ARM
shares the 598-set SIMD radix table and uses `worklist_v4_simd.txt` unchanged.
Graviton3's SVE units go unused.

## Instance choice

The harness adapts to any shape without editing — it reads `nproc` and `MemAvailable`
and derives concurrency from the measured 4.4× RSS factor.

| instance | GB/core | cores used 64M→512M | est. h/sweep | 24 sweeps | on-demand | spot |
|---|---|---|---|---|---|---|
| **m7g.4xlarge** (16 vCPU, 64 GB) | 4.0 | 16 / 16 / 16 / 16 | ~6.6 | ~170 h | ~$111 | **~$33** |
| m7g.8xlarge (32 vCPU, 128 GB) | 4.0 | 32 / 32 / 32 / 32 | ~4.7 | ~121 h | ~$158 | ~$47 |
| c7g.16xlarge (64 vCPU, 128 GB) | 2.0 | 52 / 64 / 52 / 48 | ~3.5 | ~90 h | ~$210 | ~$63 |

Three things drive the recommendation:

- **4 GB/core is the sweet spot.** The 512M tier needs 17.6 GB per job at 8 threads,
  i.e. 2.2 GB/core. `c7g`'s 2.0 GB/core is marginally short and leaves cores idle
  there; `r7g`'s 8 GB/core is mostly wasted on this workload.
- **The work is memory-bandwidth bound, so bigger instances scale sublinearly while
  costing linearly.** c7g.16xlarge is ~4× the cores of m7g.4xlarge for ~1.9× the
  throughput at ~3.5× the price. Buy a bigger instance to finish sooner, not to save
  money.
- **Use spot.** `run-plan.sh` is resumable — a completed sweep is skipped on restart —
  so an interruption costs at most one sweep. That is close to ideal for spot pricing
  and takes the whole matrix to roughly the price of a takeaway.

30 GB of gp3 is ample; nothing here is disk-heavy.

## Schedule — 24 sweeps, uncapped, all 598 radix sets

| block | modes | threads | types | shifts | sweeps |
|---|---|---|---|---|---|
| ASIMD full factorial | `asimd` | 1, 4, 16 | LL, PRP, Fermat | 0, nz | 18 |
| Thread-scaling ladder | `asimd` | 2, 8 | LL | 0 | 2 |
| Scalar oracle | `nosimd` | 1, 16 | LL | 0 | 2 |
| clang axis | `asimd` @ clang | 1, 16 | LL | 0 | 2 |

Thread counts go to 16 rather than stopping at 4 because on this box concurrency *is*
the experiment. The 2- and 8-thread ladder entries exist so that a thread-dependent
disagreement can be localised to a degree of concurrency rather than just "more than
one".

`nosimd` at 16 threads is not redundant with the x86 plans' scalar sweeps: it is the
scalar carry path under ARM's weak ordering at high concurrency, which nothing else in
the programme covers.

## Calibrate before committing the spend

The hours above are extrapolated from i9 measurements (the asimd sweep is assumed to
cost 1.72× an AVX2 one, the ratio SSE2 measured at, since NEON is likewise 128-bit).
**No Graviton measurement exists.** One command settles it:

```bash
time ./obj_asimd_gcc/Mlucas -m 19099651 -fftlen 1024 -radset 0 -shift 0 -iters 100 -cpu 0
```

The i9 does that in 0.9 s. Scale the table by the ratio you get. If Graviton comes in
much slower than assumed, cap with `MAXK=262144` — that is 88% of the radix sets for
roughly 40% of the time, and the cap is resume-aware.

## Output

`results-<hostname>/<tag>/results.csv`, same format as every other plan. Commit and
push the results directory before terminating the instance — that is the transfer
mechanism, and on spot it is also the insurance.
