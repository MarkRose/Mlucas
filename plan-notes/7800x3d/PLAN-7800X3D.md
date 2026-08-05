# Plan A — 7800X3D

**Target tree: `all-fixes-integration-v4` only.** `main` is not tested: it has known
AVX-512 defects, so a sweep of it would measure bugs we have already fixed and
already documented.

Runs independently of Plan B. Nothing here reads the laptop's output or waits on it.

```bash
cd plan-notes/7800x3d
./run-plan.sh plan-x3d.tsv            # resumable; safe to Ctrl-C and restart
DRYRUN=1 ./run-plan.sh plan-x3d.tsv   # show the schedule without running
```

## Why this box gets this work

- **`avx512` can only run here.** Zen 4 is the only AVX-512 silicon we have.
- **`nosimd` is the oracle** and the most expensive mode (3.47× AVX2, and 703 radix
  sets against 598), so it belongs on the fast machine.
- Having `nosimd`, `avx2` and `avx512` all on one box means **this machine can run
  the full scalar-vs-SIMD cross-mode differential by itself** — the single most
  valuable check in the whole plan — with no dependency on Plan B.

## Schedule — 63 sweeps, 78.3 units, ~115 h (4.8 days)

| block | modes | threads | types | shifts | units | hours |
|---|---|---|---|---|---|---|
| AVX-512 full factorial | `avx512` | 1, 2, 4, 8 | LL, PRP, Fermat | 0, nz | 17.3 | 25 |
| AVX2 full factorial | `avx2` | 1, 2, 4, 8 | LL, PRP, Fermat | 0, nz | 19.2 | 28 |
| Scalar oracle | `nosimd` | 1, 4 | LL, PRP, Fermat | 0, nz | 39.2 | 58 |
| Compiler axis | `avx512` @ clang-18, clang-21, gcc-13 | 1 | LL | 0 | 2.7 | 4 |
| | | | | **total** | **78.3** | **115** |

Full 1K–512M range throughout: no length cap. `nosimd` is held to two thread counts
because at 4.08 units a sweep it is 46% of this box's mode weight, and scalar mode has
no SIMD carry path for the thread dimension to interact with. Adding threads 2 and 8
there would cost another 1.6 days.

The compiler axis sits at AVX-512 deliberately: **#240 needs clang ≤20 *and* AVX-512
together**, so testing clang at the baseline mode would miss it. clang-18 should
reproduce the defect on stock code and must be clean on v4; clang-21 is the
known-good side of the boundary.

## Non-sweep work for this box

| tier | what | est. |
|---|---|---|
| T0 | toolchain, all 7 modes build, `-s tt` | 1 h |
| T1 | full self-test battery `-s tt/t/s/m/l/h/e`, LL and PRP, at `avx512` and `nosimd`, plus `config-fermat.sh` | 3 h |
| T7 | long-haul: one full LL to a known Mersenne prime, one full PRP with Gerbicz, one Pépin | 24 h+ |
| T8 | soak: sustained 16-thread load. **The point of doing this here** — Zen 4's double-pumped AVX-512, DDR5 and 96 MB L3 give a timing profile unlike anything the race-shaped defects (#161, #45) have been exposed to. | overnight |

T7/T8 can run after the sweeps, or on spare cores alongside the small-length tiers.

## Setup

- gcc (latest) **and** gcc-13; clang-18 **and** clang-21 — the two clang versions are
  not optional, they are the #240 regression test
- `libhwloc-dev`, `libgmp-dev`, `bc`
- **Confirm `try_avx512_asm` passes.** If the assembler rejects the extended register
  names, `makemake.sh` silently falls back to AVX2 with a warning that is easy to lose
  in a build log, and the entire AVX-512 axis quietly evaporates. Check the build log
  says `The CPU supports the AVX512 SIMD build mode`, not the fallback warning.
- 64 GB, budget 60. `run-plan.sh` exports `RAM_GB` and the concurrency follows from the
  measured 4.4× RSS factor.
- **Re-measure the top-end scaling before trusting the estimates.** The >256M figures
  extrapolate from a 1.90×-at-8-threads measurement taken on half the memory
  bandwidth. One `-fftlen 262144` run at 1 and 8 threads settles it in ten minutes.

## Output

`results-<host>/<tag>/results.csv` per sweep, plus `ANALYSIS.txt` from `compare.sh`.
Merge with Plan B's CSVs afterwards for the cross-box differential — the same mode on
different hardware must produce identical residues, which is a free extra check
neither plan needs in order to be useful on its own.
