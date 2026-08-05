# Plan C — Raspberry Pi 4 (aarch64)

**`nosimd` is not a substitute for this box.** Neither x86 plan touches `asimd` at
all, and `asimd` is not a thin wrapper over the scalar path — it is a separate SIMD
carry implementation: **217 `USE_ARM_V8_SIMD`-guarded blocks across 71 source files.**
Every one of them is currently untested by Plan A and Plan B.

Runs independently of both other plans.

```bash
# On the Pi, contained to ~/Mlucas per the standing constraint for that machine:
mkdir -p ~/Mlucas && cd ~/Mlucas
git clone -b v4-test-plan git@github.com:MarkRose/Mlucas.git .
cd plan-notes/7800x3d
MAXK=16384 ./run-plan.sh plan-pi.tsv      # resumable, and the cap is resume-aware
```

## What is uniquely testable here

1. **The `asimd` carry path itself** — 217 guarded blocks, otherwise never executed.
2. **ARM's weak memory model.** This is the strongest reason for real hardware. x86 is
   TSO; ARMv8 is weakly ordered, so a data race that is *benign in practice* on x86 can
   become observable on ARM. The two race-shaped defects in the campaign — the
   threadpool drain race (#161) and the thread-local pointer staleness check (#45) —
   are exactly this class. This is why the plan is thread-heavy (1, 2, 4) rather than
   mostly single-threaded like the x86 plans.
3. **aarch64 + clang.** #234 (`mi64_is_div_by_scalar32` type-punning) needed
   aarch64 + clang-14 + `-flto` specifically. Two clang legs are included.
4. **Cross-ISA scalar agreement.** ARM `nosimd` must be bit-identical to x86 `nosimd`.
   Both are little-endian IEEE-754, so any disagreement is a real defect, and it
   localises instantly to something ISA-dependent that is *not* SIMD.
5. **`asimd` vs `nosimd` on the same box** — separates ARM-SIMD defects from
   ARM-general ones without needing the other machines' results.

## What is *not* testable here

- **Mfactor.** Trial factoring is unimplemented on ARMv8 — `twopmodq80.c:3325` asserts
  `"No TF support on ARMv8!"`, so `test_fac` cannot run at all. Only `Mfactor -h`
  smoke tests, which is exactly the guard added in #103. Do not schedule T3 here.
- Anything AVX-512, obviously.

## Why not just use qemu on the fast box

podman `--arch arm64` works and would run the `asimd` code paths, and for pure
correctness sweeps emulation on the 7800X3D is plausibly *faster* than the real Pi.
It is still not a replacement, for two reasons:

- **qemu-user does not reproduce weak memory ordering.** It generally executes with
  host ordering semantics, so the entire point 2 above — the most valuable thing this
  box offers — is invisible under emulation.
- **An emulator disagreement is a candidate, not a bug.** SDE 8.69.1's segfaults at
  192K/256K looked like Mlucas defects and were the emulator; that cost a retracted
  claim in this campaign. The same rule applies here: anything qemu-only must be
  confirmed on the Pi before it is called a defect.

Reasonable division if you want breadth sooner: qemu on the 7800X3D for a wide
single-threaded `asimd` correctness sweep, the Pi for the multithreaded legs and as
the arbiter of anything qemu flags.

## Schedule — 22 sweeps, capped at 16M

| block | modes | threads | types | shifts | sweeps |
|---|---|---|---|---|---|
| ASIMD full factorial | `asimd` | 1, 2, 4 | LL, PRP, Fermat | 0, nz | 18 |
| Scalar oracle | `nosimd` | 1, 4 | LL | 0 | 2 |
| clang axis | `asimd` @ clang | 1, 4 | LL | 0 | 2 |

`MAXK=16384` covers **418 of 598 radix sets (70%)**. Coverage/cost at other caps:

| cap | radix sets | est. per `asimd` sweep |
|---|---|---|
| 8M | 371 (62%) | ~0.9 h |
| **16M** | **418 (70%)** | **~1.7 h** |
| 32M | 451 (75%) | ~3.1 h |
| 64M | 490 (82%) | ~6 h |

Estimated total at 16M: **~40 h (1.7 days)**. Memory is *not* the constraint — even a
4 GB Pi handles a single job up to ~116M (RSS is 4.4× the `k × 8 KB` array). Time is.

**These figures are extrapolated, not measured** — assumed 12× the i9 per core and
2.2× parallel speedup on four A72s. Calibrate before committing to a cap:

```bash
time ./obj_asimd/Mlucas -m 19099651 -fftlen 1024 -radset 0 -shift 0 -iters 100 -cpu 0
```

The i9 does that in 0.9 s. Divide to get the real factor and rescale the table above.
If the Pi turns out slower than assumed, drop to `MAXK=8192` — it still covers 62% of
radix sets, and the `asimd` path is the same code at every length.

## Setup

- gcc and clang; `libhwloc-dev`, `libgmp-dev`, `bc`
- **Keep everything under `~/Mlucas`** on that machine.
- The Pi was offline when this plan was written, so its RAM and core clock are
  unconfirmed. `run-plan.sh` reads `MemAvailable` itself, so concurrency adapts
  without editing anything.
- Thermals: a Pi 4 under sustained four-core FP load will throttle without a heatsink
  or fan. That stretches the estimates but changes no residue.

## Output

`results-<hostname>/<tag>/results.csv`, same format as the other two plans. Commit and
push the results directory; the cross-ISA `nosimd` comparison then falls out of
`./compare.sh results-*/nosimd-*/results.csv` once all three boxes' results sit side
by side.
