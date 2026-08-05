# Common reference for the two test plans

The executable plans are **[PLAN-7800X3D.md](PLAN-7800X3D.md)**,
**[PLAN-LAPTOP.md](PLAN-LAPTOP.md)** and **[PLAN-PI.md](PLAN-PI.md)**; each runs
independently. This file holds the
shared measurements, methodology and scope behind both.

Everything below is sized from measurements taken on the i9-10885H (AVX2, gcc 16.1.1)
on 2026-08-05, not from estimates. Assets in this directory:

| file | what it is |
|---|---|
| `gen_worklist.c`, `gen_stubs.c` | enumerates every supported FFT length and radix set, with a valid prime test exponent |
| `worklist_v4_simd.txt`, `worklist_v4_scalar.txt` | **the operative worklists** — generated against `integration-v4` |
| `worklist_simd.txt`, `worklist_scalar.txt` | `main` worklists, kept only to document that the tables differ per tree |
| `run-plan.sh` | executes a per-box plan; resumable across days |
| `plan-x3d.tsv`, `plan-laptop.tsv`, `plan-pi.tsv` | the three schedules |
| `sweep.sh` | one full (length × radix set) sweep for one configuration, emits CSV |
| `compare.sh` | the three differentials; `--selftest` proves they fire |

---

## 1. What this machine actually changes

**It is the first box in this campaign with native AVX-512.** The current box is a
Comet Lake i9-10885H, which has none — every AVX-512 conclusion we have reached
came through Intel SDE, which is slow, models *Intel* semantics, and has burned us
before (SDE 8.69.1's segfaults at 192K/256K turned out to be the emulator, not
Mlucas; that cost a retracted claim). Zen 4 implements the full AVX-512 ISA subset
`makemake.sh` asks for — `f/cd/dq/bw/vl` plus FMA — so all of it becomes directly
executable at full speed.

Three consequences worth planning around, beyond "we can now run AVX-512":

- **`makemake.sh` with no mode argument will now select AVX-512.** The Linux branch
  greps `/proc/cpuinfo` for `avx512` and, if `try_avx512_asm` passes, builds
  `-DUSE_AVX512 -march=native …` (`makemake.sh:360`). Every previous local "native"
  result in this campaign was AVX2. Anything comparing against those needs re-basing.
- **Zen 4 double-pumps 512-bit ops through 256-bit datapaths.** Semantically
  identical, timing profile completely different from both SDE and Intel AVX-512.
  That matters for the race-shaped defects — the threadpool drain race (#161) and
  the thread-local pointer staleness check (#45) — where exposure is a function of
  timing. This is a genuinely new test, not a re-run.
- **96 MB L3.** FFT lengths up to roughly 6M largely fit in cache. Again a new
  timing regime, and it makes the bulk of the sweep very fast.

What it does *not* give us: it is still 8 cores / 16 threads, same as the current
box, so the thread-count dimension is not new hardware territory.

## 2. Scope — "all compatible modes"

Executable natively on Zen 4:

| mode | note |
|---|---|
| `nosimd` | scalar double |
| `sse2`, `avx`, `avx2` | |
| `avx512` | **new capability** |
| `avx512_skylake` | deprecated alias; SKX AVX-512 is a subset of Zen 4's, so it runs |

Not executable here, and not because of anything we can fix:

| mode | why |
|---|---|
| `avx512_knl` | `-march=knl` emits AVX512ER/PF, which exist only on Knights Landing. Will `SIGILL` on Zen 4. Compile-only. |
| `k1om` | IMCI512, 1st-gen Xeon Phi. Needs the MPSS cross-SDK to build and real KNC to run. Compile-only. |
| `asimd` | ARM. Covered by [PLAN-PI.md](PLAN-PI.md) on the Raspberry Pi 4 — **not** redundant with `nosimd`: 217 `USE_ARM_V8_SIMD` blocks across 71 files that no x86 plan executes. Note `USE_ARM_V8_SIMD` defines `USE_SSE2` (`platform.h:222`), so ARM shares the 598-set SIMD radix table and uses `worklist_v4_simd.txt` unchanged. |

So the honest answer to "all compatible modes" is **five executable modes on x86**,
`asimd` on the Pi, and two that remain build-coverage only. SDE does not rescue the KNL pair either — SDE
removed `-knl`/`-knm` at 9.38, and 8.69.1 segfaults on kernel 6.18.

## 3. Measured scope of "every radix"

Produced by compiling `get_fft_radices.c` under each mode's `-D` define and
enumerating exhaustively (it is a pure table lookup, so this is exact, not parsed):

| tree | | supported FFT lengths | radix sets |
|---|---|---|---|
| `main` | scalar (`nosimd`) | 153 | **708** |
| `main` | every SIMD mode | 153 | **603** |
| `integration-v4` | scalar | 152 | **703** |
| `integration-v4` | every SIMD mode | 152 | **598** |

The scalar and SIMD universes differ because 45 `#ifdef USE_SSE2` blocks gate
radix-set availability; all four SIMD modes share one table. Lengths run 1K →
524288K (512M), max 12 radix sets at one length (1024K). Odd parts present: 1, 3, 5,
7, 9, 11, 13, 15, 31, 63.

**The table is not the same on every tree, so regenerate the worklist per tree.**
v4 differs from main by exactly five radix sets: it drops 1K entirely (2 sets — the
length is now rejected outright, `must be in range [2,524288]K`), 31744K goes 2 → 1,
and 65536K goes 10 → 8. Running main's worklist against a v4 binary produces
spurious failures for precisely those cells.

Two method notes, both learned the hard way here:

- A text grep of the source suggests 198 lengths / 826 radix sets. That is wrong — it
  double-counts both arms of every `#ifdef`. Enumerate, don't grep.
- Build the generator's own translation units **without** the `-m` ISA flags; pass
  only the `-D` define. The define selects the radix table; the flags let gcc
  vectorise `given_N_get_maxP`'s float code into instructions the host may not have.
  v4 additionally needs a `MODULUS_TYPE` stub that main does not.

### Measured cost inputs

All measured on the i9 on 2026-08-05, AVX2 unless stated:

| quantity | value |
|---|---|
| solo run time | 0.88 ms/kblock/100 iters at ≤16M, rising to 1.01 at 64M (mild superlinearity) |
| peak RSS | **4.4× the main array** (at 64M: 512 MB array, 2232 MB RSS) → 17.6 GB at 512M |
| parallel speedup, 16M | 1.9× at N=2, 3.0× at N=4, **4.0× at N=8** (memory-bandwidth bound) |
| parallel speedup, 64M | 1.9× at N=2, 3.0× at N=4 |
| mode cost vs AVX2 | `nosimd` **3.47×**, `sse2` 1.72×, `avx` 1.11×, `avx2` 1.00× |

Two of these overturned working assumptions: RSS is 4.4× the array, not the ~2.5× I
had assumed, and **eight concurrent jobs deliver 4× throughput, not 8×** — these FFTs
are bandwidth-bound, so core count is not the limit above about 16M.

The 7800X3D is modelled at **2× per core** (higher sustained clock, better FP IPC,
some AVX-512 gain). That is deliberately conservative on the parallel side: DDR5 and
96 MB of L3 should push the N=8 efficiency above the 50% measured here, since that
figure is a DDR4/16 MB-L3 result.

### Cost of one complete sweep (603 radix sets)

With 60 GB the concurrency limit is memory only above 128M — `-P8` up to 128M, `-P6`
at 256M, `-P3` at 512M:

| band | radix sets | 7800X3D | laptop (23 GB) | laptop penalty |
|---|---|---|---|---|
| ≤16M | 420 | 0.04 h | 0.08 h | 2.0× |
| 16–64M | 75 | 0.11 h | 0.22 h | 2.0× |
| 64–256M | 71 | 0.45 h | 1.39 h | 3.1× |
| **>256M** | **37** | **0.91 h** | **4.56 h** | **5.0×** |
| **total** | **603** | **1.51 h** | **6.25 h** | 4.1× |

The `>256M` tail is **6% of the radix sets and 60% of the wall clock.** The laptop's
penalty there is 5×, entirely because 23 GB forces one job at a time where the
7800X3D runs three.

### Parallel jobs vs threads: measured, and it changes the scheduling

The FFTs are memory-bandwidth bound, and the two ways of using the cores hit the
same wall:

| | 16M | 64M | 256M |
|---|---|---|---|
| N concurrent 1-thread jobs | 4.00× @N=8 | 3.00× @N=4 | — |
| one job, N threads | — | 2.84× @4, **3.15× @8** | **1.90× @8** |
| one job, 1 thread | 1.0× | 1.0× | 1.0× |

Three conclusions:

- **Do not run the big lengths strictly serially.** A single core reaches only 1.0×
  and the machine saturates around 3–4×, so one-at-a-time single-threaded would waste
  roughly two-thirds of the achievable throughput.
- **Nor is there any point going past ~4-way.** At 256M, eight threads buy 1.90×.
  Beyond that the memory controller, not the cores, is the limit.
- **At the top end, prefer threads over concurrent jobs.** They deliver the same
  throughput, but one 8-thread job at 512M is 17.6 GB where three 1-thread jobs are
  52.8 GB, each result lands sooner, and — the reason that actually matters —
  multithreaded large-FFT runs exercise the carry-thread paths where #207 and #152
  lived. Single-threaded runs would miss that class entirely at exactly the lengths
  we can least afford to under-test.

`sweep.sh THREADS=auto` implements this: 1 thread ≤64M, 4 threads to 256M, 8 threads
above. It is deterministic, so cross-config comparison stays apples-to-apples
provided every config uses the same policy.

The 7800X3D's DDR5-6000 has roughly twice the bandwidth of the laptop's DDR4-2933, so
its saturation point sits about one doubling further out — the 1.90× measured at 256M
should be nearer 3× there. The estimates below assume that; they are the least
certain numbers in this document, since they extrapolate from half the bandwidth.

## 4. The oracle problem, and the answer

We have reference residues for only a handful of (length, exponent) pairs — the
`MersVec`/`MvecPRP` self-test tables. There is no reference for 603 radix sets, and
generating one would beg the question.

We do not need one. Mlucas says so itself: invoking `-fftlen N -radset R -iters K`
prints

> `Non-default exponent - you will need to manually verify that the residue triplets
> output for this self-test match for all FFT radix combinations!`

So the intended check is **agreement**, and agreement is falsifiable without ground
truth. Three differentials, all implemented in `compare.sh`:

1. **Cross-radix-set** — within one configuration, every radix set at a given length
   must produce the same Res64. This has never been run. It covers all 603 radix
   sets; the self-test exercises a small subset.
2. **Cross-configuration** — the same (length, radset) must agree across build mode,
   thread count, compiler, and shift. `nosimd` is the oracle: it shares no code with
   the SIMD carry paths, so scalar-vs-SIMD disagreement localises immediately.
3. **Health** — aborts, roundoff warnings, and silent no-residue exits.

This is precisely the shape that would have caught the defects already in the
matrix: #204 (all-zero residue with a *perfect* roundoff error — invisible to
`AvgMaxErr`, glaring under cross-radset comparison), #207 (agrees at 1 thread,
diverges at 2), #240 (agrees under gcc, diverges under clang ≤20).

## 5. Matrix design

The full cross product is 5 modes × 6 compilers × 603 radsets × 5 thread counts × 4
test types × 2 shifts ≈ 600k runs ≈ 7,800 CPU-hours. Not happening, and not
necessary.

Instead: **one baseline spine, then vary one dimension at a time.** Every sweep is
compared against the spine, and a defect in any single dimension shows up as a
disagreement in that dimension's sweep. This is a fractional design, so it will miss
defects that require two simultaneous off-baseline conditions — #240 is exactly such
a case (clang **and** AVX-512), so the compiler sweeps are run *at* AVX-512 rather
than at baseline.

Spine: **gcc-latest / avx512 / 1 thread / Mersenne LL / shift 0 / 100 iters / ≤256M.**

| # | dimension varied | sweeps | notes |
|---|---|---|---|
| S1 | *(spine)* | 1 | establishes the reference residue for all 566 cells |
| S2 | build mode | 4 | `nosimd`, `sse2`, `avx`, `avx2`; scalar uses the 708-set worklist |
| S3 | thread count | 4 | 2, 4, 8, 16 — at avx512 **and** avx2 for the top two |
| S4 | shift | 2 | one nonzero fixed shift, one random; at avx512 and nosimd |
| S5 | test type | 3 | Mersenne PRP, Fermat Pépin, PRP-CF |
| S6 | compiler | 4 | clang-18 and clang-21 (the #240 boundary), plus one older gcc |
| | **total** | **18 sweeps** | see below |

Weighting each sweep by its mode cost (a `nosimd` sweep is 3.47× an AVX2 one *and*
covers 708 sets rather than 603, so it alone is 4.07 sweep-units), the 18 sweeps come
to **23.7 AVX2-equivalent units**. Of those, 6.3 units need AVX-512 and can only run
on the 7800X3D; 17.4 are portable.

**Decision: no cap. Full 1K–512M, complete radix coverage, v4 only.**

The work is split across the two boxes as two independent plans:

| | sweeps | units | wall |
|---|---|---|---|
| [PLAN-7800X3D](PLAN-7800X3D.md) — `avx512`, `avx2`, `nosimd`, compiler axis | 63 | 78.3 | ~115 h (4.8 d) |
| [PLAN-LAPTOP](PLAN-LAPTOP.md) — `sse2`, `avx`, `nosimd` baseline | 25 | 31.2 | ~154 h (6.4 d) |
| [PLAN-PI](PLAN-PI.md) — `asimd`, `nosimd`, clang axis; capped at 16M | 22 | — | ~40 h (1.7 d, est.) |

Neither reads the other's output. Each carries its own `nosimd` sweep so it can run
the scalar-vs-SIMD differential — the most valuable of the three checks — on its own.
Merging the two result sets afterwards adds a free fourth check: the same mode on
different hardware must produce identical residues.

Together they cover all five executable modes across the full length range, all three
test types, both shifts, four thread counts on `avx512`/`avx2` and two on the rest.

Fermat legality is per-radix-set, not per-length: `fermat_mod_square.c:332` requires
`n/radix0` to be a power of two, so the leading radix must absorb the whole odd part.
`sweep.sh` attempts every cell and records the rejections as `skip-fermat` rather
than as failures — let the binary self-select.

## 6. Which tree

**`all-fixes-integration-v4` only.** `main` is not tested.

The earlier draft of this plan proposed sweeping both to produce a before/after
table. That is not worth the machine time: `main`'s AVX-512 paths carry defects we
have already found, fixed and documented, so a sweep of it would spend days
re-measuring known bugs. The silent-wrong-answer matrix and the forum post already
record what 21.0.2 does wrong.

What we actually want to know is whether **the fixed tree is clean**, and that needs
only v4. If a specific v4 cell turns out to disagree, running that one cell against
`main` afterwards is a minutes-long question, not a reason to sweep the whole tree.

The v4 worklists are already generated here; note they differ from `main`'s by five
radix sets (§3), so `main`'s worklists must not be used against a v4 binary.

## 6b. Result files and cross-box comparison

Every run writes one CSV row, so all comparisons are done on files after the fact —
nothing has to be watched live.

```
plan-notes/7800x3d/
  results-<hostname>/                 # per-host, so the two boxes never collide
    <tag>/results.csv                 # one row per (length, radset): res64, maxerr, rc, status
    <tag>/logs/<k>K_rs<n>.log         # kept ONLY for non-ok runs; clean passes are deleted
    build_<mode>_<cc>.log
    ANALYSIS.txt                      # written by run-plan.sh when the plan finishes
```

`run-plan.sh` runs `compare.sh` over **its own** results at the end. To get the
cross-box differential, put both trees side by side and glob across them:

```bash
./compare.sh results-*/*/results.csv          # all boxes, all sweeps
./compare.sh results-*/nosimd-*/results.csv   # e.g. just the two scalar oracles
```

The transfer is the branch itself: commit `results-<hostname>/` on the box that
produced it, push, and pull on the other. Roughly 90 KB per sweep, so ~6 MB for Plan A
and ~2 MB for Plan B — small enough for git, and it keeps the results with the plan
and the exact worklists they were run against.

A cross-box run adds a fourth differential for free: **the same mode on different
hardware must produce identical residues.** Both plans include `nosimd`, so that
comparison is available even though the two boxes share no other mode.

## 7. Beyond the FFT sweep (split across the two plans)

| tier | what | est. |
|---|---|---|
| T0 | toolchain install, all 7 modes build, `-s tt` passes | 1 h |
| T1 | full self-test battery: `-s tt/t/s/m/l/h/e`, LL and PRP, × 5 modes, + `config-fermat.sh` | 4 h |
| T2 | the 18-sweep matrix above | 15 h |
| T3 | Mfactor: 6 word variants × 5 modes, `test_fac`, `-m 127 -bmax 20` | 2 h |
| T4 | P-1: stage 1, stage 2, and restart-resume for the five known P-1 defects (#165, #177, #196, #134, #72) | 4 h |
| T5 | sanitizers: ASan, UBSan, TSan on `nosimd` and native | 6 h |
| T6 | hwloc and GMP build variants | 1 h |
| T7 | long-haul: one full LL to a known Mersenne prime, one full PRP with Gerbicz, one Pépin | 24 h+ |
| T8 | soak: the race-shaped defects under sustained 16-thread load, which is where the new timing profile earns its keep | overnight |

T3 has a hard prerequisite: `Mfactor -m 127 -bmax 20` aborts on stock main
(`Assertion '!i' failed: There were errors writing the savefile`) and needs
**#193 + #82 + #114**. See #224.

## 8. Setup checklist

- gcc: latest plus at least one older major (the campaign has hit version-dependent
  codegen twice)
- clang: **one in 14–20 and one in 21+** — this is the #240 boundary and the only way
  to keep that regression test honest
- `libhwloc-dev`, `libgmp-dev`, `bc`
- podman (ARM/container coverage stays here — the 7800X3D does not replace the Pi)
- confirm `try_avx512_asm` passes, i.e. the installed assembler accepts the extended
  register names; otherwise `makemake.sh` silently downgrades to AVX2 with a warning
  that is easy to miss in a build log
- RAM is **64 GB**, budget 60 GB. `sweep.sh` derives concurrency from `RAM_GB` and the
  measured 4.4× RSS factor, giving `-P8` to 128M, `-P6` at 256M, `-P3` at 512M.

## 9. Smoke-test result: the harness works, and the fix stack shows up in it

`sweep.sh` was run over lengths 1–64K (75 runs, seconds) on both trees, AVX2, to
validate the harness before committing to the full plan.

**On `main`**, three cells **exit 0 having produced no residue and no error** — 1K
radset 0, 1K radset 1, 2K radset 1. Reproduced standalone:

```
$ ./Mlucas -m 21647 -fftlen 1 -radset 0 -shift 0 -iters 100 -cpu 0
…
Initial DWT-multipliers chain length = [long] in carry step.
$ echo $?
0
```

The log simply stops. Silent success having done no work is invisible to any check
that inspects only residues that exist.

**On `integration-v4`, all three are loud.** 1K aborts with
`ERROR: FFT-length argument = 1, must be in range [2,524288]K` (the length was
removed from the table), and 2K radset 1 produces a proper report:

```
  Self-test summary: 0 of 1 (FFT length, radix set) case(s) ran and gave the expected residue;
  Self-test FAILED:
    1 FFT length(s) had too few usable radix sets and were skipped - they were NOT tested.
```

So this is not an open bug — it is the fix stack (#216 making the self-test able to
fail, plus the radix-table cleanup) doing exactly what it was built to do, visible as
a clean before/after in the harness output. That is the more useful result: it
confirms the sweep detects the silent-no-op class, using a case where we already know
the answer, which is the standard this campaign has had to learn to hold itself to.

Both runs are otherwise 72/72 clean, so the harness produces no false positives on
known-good cells.

## 10. Decisions taken

- **64 GB, budget 60.** Concurrency is memory-bound only above 128M.
- **Both boxes run in parallel.** The laptop cannot do AVX-512 and is 5× slower above
  256M, so it takes T3–T6 (Mfactor, P-1, sanitizers, hwloc) plus podman/ARM, rather
  than a share of the sweeps.
- **v4 only.** `main` is not swept; see §6.
- **No cap — complete coverage, full 1K–512M.** Time is not the constraint.
- **Two independent plans**, one per box, neither blocking the other. See §5.
- **Concurrency: `THREADS=auto`.** Bandwidth-bound above ~128M, so fewer jobs with
  more threads each, not more concurrent jobs. See §3.
