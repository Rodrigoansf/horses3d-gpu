# Stack PRs #113–#117: where things stand

## 0. Current branches (13 Oct 2026): one PR per branch, nothing opened yet

Everything below section 0 is the 7 Oct state. The branches named there (`fix/gpu-port-*`, `discuss/legacy-shared-bugs`, `stack-pick/*`) are **superseded** by the ones in this table. They are kept only because the laptop's round-2 task file refers to their commits.

Minor fixes don't change results in anything that runs today. Each "change" branch changes results somewhere, so it is kept alone to be discussed on its own.

**horses3d-gpu** (fork Rodrigoansf/horses3d-gpu):

| Branch | Base | What |
|---|---|---|
| `fix/minor-develop` | `develop` | 9 commits: Face_Assign, NodalStorage mapping, enter/exit data balance, `sem` teardown, ActuatorLine guard, 3 OpenMP fixes, multiphase "source" monitor |
| `fix/minor-GMM` | `GMM_develop` | 5 commits: Face_Assign, NodalStorage mapping, `make mu` build fix, TE sensor `pAdapt_MPI`, sensor OpenMP `shared` lists |
| `change/strong-form-split-fluxes` | `develop` | split-form sharp fluxes never computed (port commented the call out), in the strong-form volume term and the aliasing sensor |
| `change/svv-energy-divv` | `GMM_develop` | SVV `divV` index + TaylorGreenSVVLES references (same values as legacy) |
| `change/te-sensor-source-term` | `GMM_develop` | TE sensor source term: right point, `S = 0` |
| `change/limiter-pressure-reference` | `develop` | limiter uses p(q_avg); LimiterTest references updated (legacy reproduces both old and new) |
| `fix/aliasing-sensor-realloc` | `develop` | aliasing sensor freed its scratch arrays when the next element had the same order (crash on 2nd element; legacy too) |

**legacy horses3d** (fork Rodrigoansf/horses3d, base `master` `e23a7a2`):

| Branch | What |
|---|---|
| `legacy/minor-fixes` | TE sensor `pAdapt_MPI` + sensor OpenMP `shared` lists (both crashes, reproduced) |
| `legacy/te-sensor-source-term` | TE sensor source term |
| `legacy/svv-energy-divv` | SVV `divV` + TaylorGreenSVVLES references |
| `legacy/limiter-pressure-reference` | limiter uses p(Qavg) |
| `legacy/aliasing-sensor-realloc` | aliasing sensor scratch-array realloc (crash on 2nd element) |

`legacy/te-sensor-padapt-mpi` and `legacy/sc-sensor-omp-shared` are superseded by `legacy/minor-fixes`. The proxy refused to delete them; delete by hand.

Note on the limiter: section 2 below says it was dropped. It is back as a *change* branch, to be discussed together with the legacy one. The new references are exactly what legacy produces with the same change.


All work is on the fork, Rodrigoansf/horses3d-gpu. Nothing has been pushed to horses-framework.

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
