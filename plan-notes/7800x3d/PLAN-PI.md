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
MAXK=32768 ./run-plan.sh plan-pi.tsv       # capped; the cap is resume-aware
```

## Schedule — 7 sweeps, capped at 8M

| sweep | why it is in the subset |
|---|---|
| `asimd` t1 LL s0 | baseline; the cell every other result is read against |
| `asimd` t4 LL s0 | multithreaded on A72 — weak ordering on the second µarch |
| `asimd` t4 LL s-nz | shift dimension (#152, #231, #232, #190) under threads |
| `asimd` t4 PRP s0 | the other Mersenne test type |
| `asimd` t1 Fermat s0 | Pépin path (#232 is Fermat + nonzero shift) |
| `nosimd` t1 LL s0 | local oracle, and must be bit-identical to x86 `nosimd` |
| `asimd` t1 LL s0 @ clang | the aarch64+clang axis on A72 codegen |

`MAXK=32768` covers **451 of 598 radix sets (75%)**, estimated **~40 h total**.

| cap | radix sets | est. per `asimd` sweep | est. total (7 sweeps) |
|---|---|---|---|
| 4M | 316 (53%) | ~0.7 h | ~6 h |
| 8M | 371 (62%) | ~1.6 h | ~12 h |
| 16M | 418 (70%) | ~3.0 h | ~22 h |
| **32M** | **451 (75%)** | **~5.4 h** | **~40 h** |

For reference when choosing a cap in future: all **34 distinct leading radices** and
both trailing DFT radices (16, 32) are already reachable at a 4M cap, so above that a
longer FFT chains more radix-16/32 passes rather than reaching new code. The cap buys
more (length, radset) combinations and larger working sets, not new macros.

The `nosimd` sweep is the single most expensive cell in the plan — scalar is 3.47×
`asimd` and runs 476 radix sets rather than 371 — so it is ~3.2 h of the ~12 h on its
own. Drop it if you only care about the SIMD path, but it is what lets this box
compare against x86 `nosimd` bit-for-bit.

Note these figures include the **1.72× NEON factor**: ASIMD is 128-bit, so it costs
about what SSE2 measured on the i9, not what AVX2 did.

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
