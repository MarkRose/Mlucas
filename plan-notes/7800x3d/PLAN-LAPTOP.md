# Plan B — laptop (i9-10885H)

**Target tree: `all-fixes-integration-v4` only.** Same reasoning as Plan A: `main`
has known AVX-512 defects and testing it would re-measure documented bugs.

Runs independently of Plan A. Nothing here reads the 7800X3D's output or waits on it.

```bash
cd plan-notes/7800x3d
./run-plan.sh plan-laptop.tsv            # resumable
DRYRUN=1 ./run-plan.sh plan-laptop.tsv
```

## Why this box gets this work

This machine has **no AVX-512**, ~half the per-core throughput and 30 GB rather than
64, so it takes the mid-ISA modes nobody else has time for. Two constraints shaped the
split:

- Its penalty is **entirely at the top end** — 2.0× the 7800X3D up to 64M, but 5×
  above 256M, purely because 23 GB available forces one job where 60 GB runs three.
  `THREADS=auto` recovers most of that by using 8 threads on one job instead of
  parallel jobs (see PLAN.md §3), which is why the full range stays affordable here.
- It gets a **`nosimd` baseline of its own** so it can run its own scalar-vs-SIMD
  cross-mode differential without waiting on Plan A. That one sweep is 20 h of the
  154, and it is what makes this plan independently meaningful rather than just a
  pile of data for someone else to interpret.

## Schedule — 25 sweeps, 31.2 units, ~154 h (6.4 days)

| block | modes | threads | types | shifts | units | hours |
|---|---|---|---|---|---|---|
| SSE2 | `sse2` | 1, 4 | LL, PRP, Fermat | 0, nz | 16.5 | 81 |
| AVX | `avx` | 1, 4 | LL, PRP, Fermat | 0, nz | 10.7 | 53 |
| Scalar oracle (baseline only) | `nosimd` | 1 | LL | 0 | 4.1 | 20 |
| | | | | **total** | **31.2** | **154** |

Full 1K–512M range: no length cap. Two thread counts rather than four — the thread
dimension is covered to four levels on the 7800X3D at `avx512` and `avx2`, and
`sse2`/`avx` share the same carry-thread code paths as `avx2`, so the marginal value
of 2 and 8 threads here is low relative to 4 more days of runtime.

If you want the box back sooner, the honest trims in order of least loss:

| trim | saves | costs you |
|---|---|---|
| drop `MAXK=262144` (skip >256M) | 78 h | the 37 largest radix sets at `sse2`/`avx` — the 7800X3D does not cover those modes at all, so this is a real coverage hole, not a duplicate |
| drop the `nz` shift column | 77 h | shift-dependent defects (#152, #231, #232, #190) at `sse2`/`avx` |
| drop threads=4 | 51 h | multi-thread defects (#207) at `sse2`/`avx` |

## Non-sweep work for this box

Everything that does not need AVX-512 or 60 GB. This is where the laptop genuinely
earns its keep, and it can run alongside the sweeps since these are mostly
single-threaded or short:

| tier | what | est. |
|---|---|---|
| T3 | Mfactor: 6 word variants × 5 modes, `test_fac`, `-m 127 -bmax 20`. **Needs #193 + #82 + #114** — without #114 the run aborts on the savefile write-back (see #224). | 2 h |
| T4 | P-1: stage 1, stage 2, and restart-resume for the five known P-1 defects (#165, #177, #196, #134, #72) | 4 h |
| T5 | sanitizers: ASan, UBSan, TSan on `nosimd` | 6 h |
| T6 | hwloc and GMP build variants | 1 h |
| — | podman/qemu ARM (`asimd`) and container-matrix coverage — stays here permanently, the 7800X3D does not replace the Pi | 3 h |

Doing T3–T6 here rather than on the 7800X3D is worth more than the ~7 h the laptop
could shave off Plan A's sweeps by taking a share of them.

## Setup

- gcc (latest), `libhwloc-dev`, `libgmp-dev`, `bc`, podman
- 30 GB total; `run-plan.sh` will read ~23 GB available and tier concurrency from it
- Thermals: this is a mobile part running flat out for six days. If it throttles the
  estimates stretch, but nothing breaks — the plan is resumable and the residues do
  not care about clock speed.

## Output

`results-<host>/<tag>/results.csv` per sweep, plus `ANALYSIS.txt`. Merge with Plan A's
CSVs for the cross-box differential (same mode, different hardware, must agree).
