# Plan C — Raspberry Pi 4 (aarch64), confirmation subset

**Scope changed once Graviton became available.** [PLAN-GRAVITON.md](PLAN-GRAVITON.md)
now covers ARM breadth — all 598 radix sets, uncapped. This box is no longer trying to
do that: a full uncapped sweep here would take an estimated **247 h per sweep**, which
is not a sensible use of the hardware.

What the Pi still provides is **a second ARM microarchitecture**, and that is not
something Graviton can supply:

- **Cortex-A72, ARMv8.0-A** against Graviton's **Neoverse, ARMv8.2+**.
- **Different generated code.** `makemake.sh` uses `-mcpu=native`, so the Pi builds for
  `cortex-a72` and Graviton for `neoverse-v1`/`v2`. Same source, different instruction
  selection and scheduling — which is exactly the axis that produced #234
  (aarch64 + clang-14 + `-flto`) and the clang vectorizer defect #240 on x86.
- **The SBC population.** Raspberry Pis are what a real slice of ARM Mlucas users run,
  and A72 is a much simpler out-of-order core than Neoverse — different enough that
  "works on Graviton" does not imply "works here".

Runs independently of every other plan.

```bash
# Contained to ~/Mlucas per the standing constraint for this machine:
mkdir -p ~/Mlucas && cd ~/Mlucas
git clone -b v4-test-plan git@github.com:MarkRose/Mlucas.git .
cd plan-notes/7800x3d
MAXK=8192 ./run-plan.sh plan-pi.tsv        # capped; the cap is resume-aware
```

## Schedule — 24 sweeps, capped at 8M, ~39 h

**Why a modest cap and many dimensions, rather than the reverse.** The ARM code
surface is **34 distinct leading radices × 2 trailing DFT radices (16 and 32)**, and
*all* of it is reachable at a **4M** cap. Measured by enumerating every radix set:

| cap | radix sets | distinct leading radices | distinct trailing radices |
|---|---|---|---|
| 4M | 316 (53%) | **34 (all)** | **2 (all)** |
| 8M | 371 (62%) | 34 | 2 |
| 32M | 451 (75%) | 34 | 2 |
| uncapped | 598 | 34 | 2 |

Past 4M, a longer FFT does not reach new code — it chains more radix-16/32 passes
through the same macros. So raising the cap buys more (length, radset) combinations of
identical code, while Graviton is already covering all 598 of them uncapped. Spending
the same hours on **dimensions** is worth more here, because thread count, test type
and shift each select genuinely different code paths.

8M rather than 4M keeps a comfortable margin above the point where coverage completes,
and adds the longer-pass-chain cases for roughly 2 h.

| block | modes | threads | types | shifts | sweeps | est. |
|---|---|---|---|---|---|---|
| ASIMD full factorial | `asimd` | 1, 2, 4 | LL, PRP, Fermat | 0, nz | 18 | 23.0 h |
| Scalar oracle | `nosimd` | 1, 4 | LL | 0, nz | 4 | 12.8 h |
| clang axis | `asimd` @ clang | 1, 4 | LL | 0 | 2 | 3.2 h |
| | | | | | **24** | **39.0 h** |

This is a *full factorial* over threads × type × shift on A72 — strictly more than the
7-cell subset it replaces, for the same wall clock.

If you would rather have the length coverage, it is one variable: `MAXK=32768` gives
451 sets (75%) but costs ~40 h for the original 7 cells only. Per-sweep costs at other
caps: ~0.7 h (4M), ~1.6 h (8M), ~3.0 h (16M), ~5.4 h (32M) for `asimd`; `nosimd` is
~2× that, being 3.47× the cost over 476 radix sets rather than 371.

These figures include the **1.72× NEON factor**: ASIMD is 128-bit, so it costs about
what SSE2 measured on the i9, not what AVX2 did.

Memory is not the constraint — even a 4 GB Pi handles a single job to ~116M (RSS is
4.4× the `k × 8 KB` array). Time is.

## Not testable here

- **Mfactor.** Trial factoring is unimplemented on ARMv8 — `twopmodq80.c:3325` asserts
  `"No TF support on ARMv8!"` — so `test_fac` cannot run. Only `Mfactor -h` smoke
  tests, which is the guard added in #103. Do not schedule T3 on this box.

## Calibrate first

Estimates assume 12× the i9 per core and 2.2× parallel speedup on four A72s; the Pi
was offline when this was written, so its RAM and clock are unconfirmed.

```bash
time ./obj_asimd_gcc/Mlucas -m 19099651 -fftlen 1024 -radset 0 -shift 0 -iters 100 -cpu 0
```

The i9 does that in 0.9 s. Divide to get the real factor.

Thermals: a Pi 4 under sustained four-core FP load will throttle without a heatsink or
fan. That stretches the wall clock and changes no residue.

## Reading the result

The interesting output is not this plan on its own — it is `asimd` here versus `asimd`
on Graviton. Identical residues across two microarchitectures and two `-mcpu` targets
is strong evidence the ASIMD carry path is correct. A disagreement localises
immediately to codegen or to a µarch-specific ordering effect, and the 7-sweep subset
is chosen so that whichever cell disagrees points at a dimension.

```bash
./compare.sh results-*/asimd-*/results.csv     # once both ARM boxes' results are in
```
