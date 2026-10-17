# Stack PRs #113–#117: where things stand

## 0. Current branches (17 Oct 2026)

Team decision (15 Oct): the review changes go in split by feature, to `develop` (horses3d-gpu) and `master` (legacy). `GMM_develop` is Rodrigo's research branch: it gets the fixes directly (no PR) and is kept merged up to `develop`. **No PRs in horses-framework yet**: fork PRs only, until everything is reviewed and tested. The 13 Oct table and everything below section 0 are history.

**horses3d-gpu**, fork Rodrigoansf/horses3d-gpu, all on `develop` = upstream `1c077fea`:

| Fork PR | Branch | What |
|---|---|---|
| #1 | `fix/minor-develop` | 11 commits: Face_Assign, NodalStorage mapping, enter/exit data balance, `sem` teardown, TE sensor `pAdapt_MPI`, sensor OpenMP `shared` lists, ActuatorLine guard, 3 OpenMP fixes, multiphase "source" monitor |
| #3 | `change/strong-form-split-fluxes` | split-form sharp fluxes never computed (strong-form volume term, aliasing sensor) |
| #4 | `change/svv-energy-divv` | SVV `divV` + TaylorGreenSVVLES references (no effect on develop yet: SC isn't applied there) — base moved from GMM_develop to develop |
| #5 | `change/te-sensor-source-term` | TE sensor source term — base moved from GMM_develop to develop |
| #6 | `change/limiter-pressure-reference` | limiter uses p(q_avg) |
| #7 | `fix/aliasing-sensor-realloc` | aliasing sensor scratch-array realloc |
| new | `fix/paramfile-scalar-dealloc` | ParamfileRegions: avoid the nvfortran 26.3 crash that breaks `Cylinder` on the GPU since horses-framework/horses3d-gpu#119 |
| #2 | `fix/minor-GMM` | obsolete: its commits are in GMM_develop now; close it |

**horses-framework GMM_develop** (pushed directly, fast-forward from `630879e6`): the five `fix/minor-GMM` commits, SVV divV + references, TE source term, **SVV on the GPU** (device port), merge of develop, split-form (2), aliasing realloc, ParamfileRegions. See `pr-drafts/gpu/2-GMM_develop-direct.md`.

**legacy horses3d**, fork Rodrigoansf/horses3d, all on `upstream-master` = upstream master `a01ca08b4`: `legacy/minor-fixes` (#1), `legacy/te-sensor-source-term` (#2), `legacy/svv-energy-divv` (#3), `legacy/limiter-pressure-reference` (#4), `legacy/aliasing-sensor-realloc` (#5).

Testing (laptop RTX 3060, nvfortran 26.3; gfortran for CPU): see each PR draft. Summary: every develop branch and GMM_develop run the GPU CI cases; anything that should not change results is bitwise identical to its base. Leak check, TE/aliasing scratch cases, CPU/GPU cross-checks and the legacy serial CI (NS + multiphase) are in the drafts.

New findings, not fixed (beyond the old list in HANDOFF.md):
- nvfortran 26.3 segfaults when deallocating an allocatable scalar component through an allocatable dummy (fixed for ParamfileRegions only).
- gfortran wraps any procedure with a procedure-level `USE` of a module that reaches IEEE_ARITHMETIC in an FP-environment save/restore (~100 ns per call). Avoided in the new SVV device routines; `SC_ComputeElementAviscFlux` still has one (per element, negligible).
- Legacy `NavierStokes/CylinderGMM` is not reproducible run to run (same binary, different residuals between runs; asserts still pass).
- `ForwardFacingStepSVV` crashes on the GPU on GMM_develop (illegal address in `HexMesh_ComputeLocalGradientNS`).
- On GMM_develop, `SC_viscosity` (host) and `SC_ComputeElementAviscFlux` (device) disagree on whether the first method acts where sensor >= 1 when there is no second method.

## 1. Blatant bugs, fixed: no team discussion needed

These bugs are GPU-only, or were introduced when porting from legacy; the fix restores legacy behaviour. None of them changes any asserted value.

**`fix/gpu-port-develop`** (on latest `develop`, `ca6f0bd2`), 8 commits:

| Fix | Kind |
|---|---|
| `Face_Assign` aliased face storage. The TE sensor's coarse mesh then freed fine-mesh data. | port bug (legacy deep-copies) |
| NodalStorage copied to the GPU only up to element 1's x-order | GPU-only |
| ActuatorLine wrote to an unallocated array in serial runs (segfault, reproduced) | GPU-repo bug |
| Strong-form split fluxes were never computed (call commented out) | port bug |
| `ENABLE_THREADS=YES` doesn't compile (ActuatorLine) | port bug |
| Every thread recomputed all boundary faces. Now uses `!$omp do` per loop, as legacy does, not the stack's `!$omp single`. | port bug |
| Shared scratch variables in the monitor OpenMP loops | port bug |
| Multiphase `"source"` volume monitor was missing | port omission (legacy has it) |

**`fix/gpu-port-GMM`** (on `GMM_develop`), 3 commits: `Face_Assign`, NodalStorage, strong-form split fluxes. These are the ones that touch the shock-capturing / TE work.

**Checked on CPU (gfortran):**
- All branches build: NS and MU, serial and threaded.
- TaylorGreen, Cylinder and LimiterTest pass, with residuals identical to `develop`.
- Cylinder passes with 4 OpenMP threads.
- TaylorGreenSVVLES on the GMM fix branch passes 8/8, as on `GMM_develop`.

**GPU (RTX 3060 laptop, cc86):** both fix branches are bitwise identical to their bases on every single-GPU CI case (17 on develop, 19 on GMM), with the same efficiency within noise. Full report: `review/gpu-results-cc86.md` on branch `review/gpu-results`.

## 2. Bugs legacy has too: need discussion and tests

**`discuss/legacy-shared-bugs`**, 4 commits on top of `fix/gpu-port-GMM`. Each commit message starts with `DISCUSS`.

| Change | Status |
|---|---|
| SVV `divV` uses the wrong index with energy gradient variables | Real bug, same line in legacy. Fixing it fails TaylorGreenSVVLES 5/8 in legacy and here, with identical numbers. Fix in legacy first and update the reference values there. |
| TE sensor: source term evaluated at node (0,0,0); `S` uninitialised | Same in legacy. No test uses the TE sensor. |
| TE sensor builds its coarse mesh with `pAdapt` under MPI | Same in legacy (documented there as not working with MPI). Untested. |
| `default(private)` sensor loops lose `sensor`, `t` and module data | Same in legacy. Threaded builds only. |

**Dropped:**
- **Positivity limiter change (#115).** Legacy uses the same formula on purpose, and the current one is safe; it only limits more than needed. The change moves away from legacy and breaks `LimiterTest` (7/8 fail).
- **Stack's test-file edits.**

## 3. GPU tests

- **One GPU (your laptop, cc86):** paste `review/gpu-test-prompt-cc86.md` into a local Claude session. It covers:
  - no-regression of both fix branches on GPU,
  - an anisotropic-order case for the NodalStorage fix,
  - whether `exit data delete(sem)` is needed,
  - stale GPU monitors,
  - SVV on GPU,
  - LimiterTest.
- **Several GPUs (cluster, by hand):**
  - `CI_parallel_GPU.yml` cases on `fix/gpu-port-develop` against `develop`, to check for regressions.
  - GMM shock-capturing cases with MPI on `fix/gpu-port-GMM` against `GMM_develop`. The AV flux is exchanged across ranks (GMM commit `8764e931`).
  - TE sensor with MPI (`pAdapt_MPI` commit). No existing case; one would have to be written.
  - Multiphase + MPI gives NaN in the GPU repo (64-rank CPU run). This is a known gap (`develop_mu_mpi`), not a test of these fixes.

## 4. Performance: decide how to implement before fixing

| Problem | Avoid | Suggested approach |
|---|---|---|
| Host-side volume monitors (kinetic energy, its rate, enstrophy, entropy …) read stale data on GPU | The stack's per-monitor copy of Q/QDot/gradients to the host, or `UpdateHostData` every step (old `TGV-monitor-fix`) | Compute these integrals on the device with OpenACC reductions, as `VectorVolumeIntegral` already does, and copy back one scalar. |
| Artificial-viscosity face prolongation is a host round trip every RHS evaluation (`GMM_develop`) | The stack's full `UpdateHostData` plus per-element updates | Port `Face_AdaptAviscFluxToFace` to the device so the AV path stays on the GPU. |
| SVV runs on the host only | The stack's per-element kernels launched from a host loop, with per-element data regions | One mesh-wide kernel per filtering pass. |
| Wall distance is computed on the CPU, O(nodes × wall points) | The stack's one kernel and data region per element | One kernel over all nodes with a min-reduction over wall points. Keep `dWall` = √huge when there are no walls. |
| Two-point flux chosen at run time inside the split kernel | The stack's 7 copies of the kernel via `#include` | Benchmark first on top of #92's fused kernel; specialise only if the `select case` cost shows up. |
| TE sensor on GPU | The stack's Q/QDot round trips on every sensor evaluation | Low priority; design together with the AV path. |

## 5. New bugs found by the GPU run (not fixed yet)

| Bug | Where | Kind |
|---|---|---|
| Anisotropic orders (Nx≠Ny≠Nz) crash on the GPU in `HexMesh_ProlongSolToFaces`, even on a conforming mesh. The NodalStorage commit is necessary but not enough. | develop, GMM | GPU-only, cause not found yet |
| p-nonconforming faces give NaN even on CPU: the port's `Face_AdaptSolToFace` only copies, and lost legacy's `projectionType`/`Tset` interpolation | develop, GMM | port bug (legacy works) |
| GPU volume monitors frozen: kinetic energy stays at its initial value, kinetic-energy rate and enstrophy are 0 at every iteration | develop, GMM | GPU-only; fix on the device (section 4) |
| SVV on GPU gives wrong results (TaylorGreenSVVLES 3/8): the host branch uses stale Q and gradients, and the element AV flux never reaches the device | GMM | GPU-only; a 7-line host round trip proves the cause (8/8), but the real fix is SVV on the device |
| ForwardFacingStepSVV crashes on the GPU in `HexMesh_ComputeLocalGradientNS` | GMM | GPU-only, cause not found yet |
| `make mu` does not compile on the GMM-based branches (`NSGradientVariables_selector` / `Q_grad_NS` under `-DMULTIPHASE`) | GMM | build bug |
| About 7.2k device allocations never freed: unbalanced enter/exit data in `HexMesh_CreateDeviceData`; `geom%x` is copied in twice; multiphase `main` has no device cleanup | develop, GMM | GPU-only, harmless at exit |
| `exit data delete(sem)` | develop | not needed for correctness; fold into the cleanup above |

## Branch map (fork)

- **Use:** `fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`.
- **Reference only, superseded:** `stack-pick/*`, `zalbanob-stack/*`.
- **Report:** `review/stack-prs-113-117.md` on `claude/eager-lamport-ymhyjk`.
- **GPU results:** `review/gpu-results-cc86.md` on `review/gpu-results`.
