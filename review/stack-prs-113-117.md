# Review of the zalbanob stack PRs (#113 – #117)

Readable version: https://claude.ai/artifact/R77XqmjoS9u2eSkvakzFwp (private; share it from the page if needed).

Scope: horses-framework/horses3d-gpu#113, #114, #115, #116, #117 (branches
`stack/01-foundation` … `stack/05-monitor-fix` in zalbanob/horses3d-gpu).
Each layer is one squashed commit on top of the previous one, all starting from
`main` at `e2eff561` (#97). Compared against `develop` (`8a656032`), `main`,
`GMM_develop`, Miguel's gradient-variables work (`miguel_gradients_consistency`,
#107) and the other open PRs.

Only compressible NS and multiphase were treated as in scope; NSSA / iNS / CAA
changes are marked "out of scope".

## How this was checked

* Every hunk was read and compared with the corresponding code on `develop`,
  `main`, `GMM_develop` and #107.
* No GPU is available here. All candidate branches were compile-checked on CPU
  with gfortran 13 (`make ns` and, where relevant, `make mu`, serial; the OpenMP
  branch with `ENABLE_THREADS=YES`).
* `NavierStokes/LimiterTest` was run on CPU for `develop` and for the limiter
  branch (see below).
* Nothing has been run with nvfortran/OpenACC, MPI, or the GPU CI. Every
  verdict about GPU behaviour comes from reading the code.

## Summary

| Verdict | What |
|---|---|
| **Take** | Positivity limiter reformulation (#115, a numerics change); 4 confirmed general bug fixes + 1 housekeeping change; 3 shock-capturing bug fixes; GPU monitor host refresh + MU "source" monitor; optional CPU-OpenMP fixes |
| **Duplicate (discard)** | Gradient-variable dispatch and entropy velocity-gradient fix (= #107); device artificial viscosity, central AviscFlux face term, AviscFlux device mapping, GMM `maxloc` workaround (= `GMM_develop`); local gradients in the elliptic base class (= #107 / `arr/missing_terms_grad_vars`) |
| **Regression (discard)** | `#ifdef _OPENACC` wrapping of directives (dead code); GPU IBM wall-function step compiled out; revert of #92 and #97 (both on `main`); N>0 guards inside ACC loops; split-form kernel copied 7× via `#include`; host round-trips of the whole mesh every RHS for AV/SVV; AviscFlux added after the BC on boundary faces; unexplained 3× change of ForwardFacingStepSVV reference residuals |
| **New but not mergeable as is** | GPU wall distance, SVV port to GPU, TE sensor on GPU |

## Branches to use (in Rodrigoansf/horses3d-gpu)

| Branch | Base | Commits | Content |
|---|---|---|---|
| **`stack-pick/ready`** | `develop` | 10 | Confirmed bug fixes, ready to PR. None of them touches a test file or changes a value any active test asserts. |
| **`stack-pick/needs-analysis`** | `stack-pick/ready` | 5 | Changes to look at slowly. Each commit message starts with `NEEDS ANALYSIS:` and says why. |

`ready`:
1. `Face_Assign` deep copy
2. NodalStorage device mapping
3. ActuatorLine unallocated assignment
4. Strong-form split fluxes
5. TE sensor `x(:,i,j,k)` and `S = 0`
6. TE sensor `pAdapt_MPI`
7. OpenMP: boundary flux on one thread
8. OpenMP: `shared` lists in the sensor loops
9. OpenMP: actuator-line construct (makes `ENABLE_THREADS=YES` compile)
10. OpenMP: privatised monitor temporaries

`needs-analysis`:
- `exit data delete(sem)`: unverified.
- SVV `divV`: changes TaylorGreenSVVLES results on `GMM_develop` and breaks its original asserts (no effect on `develop`).
- Positivity limiter: changes LimiterTest asserts.
- Monitor refresh: partial fix.
- MU `"source"` monitor: a feature, and it edits a test.

The test asserts come from the reference code. A commit that changes an asserted
value is only acceptable if the reference code has the same bug, so the limiter
and the SVV `divV` change both need a comparison against the reference code first.

The per-topic branches below are kept for reference; `ready` + `needs-analysis`
supersede them.

## Per-topic candidate branches (superseded)

All commits keep zalbanob as author, with a message saying which stack layer
they come from. Each commit is self-contained and can be cherry-picked on its own.

| Branch | Base | Commits | Checked |
|---|---|---|---|
| `stack-pick/positivity-limiter` | `develop` | 1 | builds; LimiterTest passes on CPU against the new reference values |
| `stack-pick/bugfixes` | `develop` | 5 | `make ns`, `make mu` |
| `stack-pick/sc-fixes-on-GMM` | `GMM_develop` | 3 | `make ns` |
| `stack-pick/gpu-monitors` | `develop` | 2 | `make ns`, `make mu` |
| `stack-pick/cpu-openmp-fixes` (optional) | `develop` | 4 | `make ns`, `make mu` with `ENABLE_THREADS=YES` |

### `stack-pick/positivity-limiter` (from #115)

**This is a numerics change, not a safety fix.** `stage_limiter` builds theta_p from the
volume-averaged nodal pressure. Since p(q) is concave, that mean is <= p(q_avg),
and theta = (x - eps)/(x - p_min) increases with x. So the old theta_p is never
larger than the Zhang-Shu one, and the old limiter still keeps p >= eps. It just
limits more than needed, which adds dissipation. When the nodal mean drops below
eps it collapses the cell to its average, which is still positive.

The one case where the old code really fails: when every nodal pressure is equal
(mean == min) and below eps, no limiting happens at all.

#115 switches to p(q_avg), the textbook form. Results change (LimiterTest
reference values were updated by the author on GPU). No branch in the group
has this.

Validation (CPU, gfortran, 100 steps of LimiterTest):

* `develop` passes against the old reference values.
* The branch passes against the new values.
* The two sets differ by ~5e-6 relative and the tolerance is 1e-7, so the test
  does tell them apart.

The GPU CI still has to confirm the new values. Treat this like any other change
to the numerics, with the usual V&V.

### `stack-pick/bugfixes` (from #113, #116)

1. **`Face_Assign` deep copy.** It allocated `to%geom`/`to%storage`, then
   pointer-assigned them to `from`, which leaked memory and aliased the faces.
   It is used by `coarseSem = sem` in the TE sensor, so the coarse mesh's
   `pAdapt` reallocated face data the fine mesh still uses.
2. **NodalStorage device mapping.** The loop ran to `self%Nx(1)`, the x-order of
   *element 1*, so anisotropic or p-nonconforming meshes left higher orders
   unmapped. It now maps every constructed order, maps `sharpD` only if it is
   allocated, and deletes `w`/`x` on exit. Ported with develop's per-entry
   mapping, not the stack's whole-array copyin.
3. **ActuatorLine.** Zeroing `newPointToFind` was an assignment to an
   unallocated array in serial runs. Reproduced with gfortran: a segfault in
   release, "Assignment of scalar to unallocated array" with `-fcheck=all`. It
   happens on the non-projection branch of `UpdateFarm`.
4. **Strong-form split volume term** (isolated time derivative / TE). The call
   that fills `fSharp/gSharp/hSharp` was commented out, so the routine
   integrated uninitialised arrays.
5. **NS `main`.** Adds `!$acc exit data delete(sem)` to balance the `enter data
   copyin(sem)`. This is **not a demonstrated bug**: it runs at program end, and the
   author's teardown segfault could not be checked here. Housekeeping only. The
   multiphase main has the same imbalance but no device teardown at all, so it was
   left alone.

### `stack-pick/sc-fixes-on-GMM` (from #116, based on your shock-capturing branch)

1. **`SVV_physical_dissipation_ENERGY`.** `divV = Hx(IX)+Hy(IY)+Hz(IZ)` summed
   d(rho)/dx + du/dy + dv/dz. With energy gradient variables the velocity
   gradients are at `IRHOU:IRHOW`, which the rest of the routine already assumes.
2. **TE sensor.** It passed the whole `ce%geom%x` array to a dummy `x(NDIM)`, so
   every node used node (0,0,0). It now uses `x(:,i,j,k)`. It also sets `S = 0`
   before the call, and that is the bigger fix: `S` is an uninitialised local, and
   the default problem file's `UserDefinedSourceTermNS` never assigns it, so the
   truncation-error estimate added garbage for every case without a user source
   term.
3. **TE sensor.** It now uses `pAdapt_MPI` for the coarse mesh in MPI runs. This
   has not been tested with MPI.

These fixes apply identically to `develop` (the code is unchanged there). They are
based on `GMM_develop` so they merge cleanly into your work.

### `stack-pick/gpu-monitors` (from #117)

1. **Host refresh for monitors on GPU (partial fix).** `ScalarVolumeIntegral`
   runs on the host, and on GPU builds host data is only refreshed when a solution
   file is saved. The fix pulls Q/QDot only for the kinetic-energy-rate/balance and
   entropy-rate/balance monitors. Kinetic energy, enstrophy, entropy and the other
   host-side integrals stay stale, so after this commit the rate is fresh and the
   value it is the rate of is not.

   The fix also adds a device-to-host copy on every evaluation of those monitors.
   The TaylorGreen GPU test asserts KE, KE rate and enstrophy at 1e-11 tolerance;
   I could not determine which iteration that buffer entry holds, so I could not
   confirm the stale data shows up in practice. A single refresh before the
   host-side monitors (like `TGV-monitor-fix`, but including QDot) would be the
   complete fix.
2. **Multiphase `"source"` volume monitor.** This is **a feature, not a bug fix.**
   The MU ActuatorLineInterpolation case uses it and the MU monitor rejected it.
   The commit also makes that test's ProblemFile return early when no volume
   monitor exists. That case is still commented out in the MU CI.

### `stack-pick/cpu-openmp-fixes` (optional)

Only relevant to `ENABLE_THREADS=YES`, which no CI job runs. **`develop` does not
compile with `ENABLE_THREADS=YES`** (gfortran), because of a stray `!$omp end do`
and the undeclared `Q`/`Qtemp` in `ActuatorLine.f90`. This branch fixes that and:

* puts `computeBoundaryFlux` under `!$omp single`, in both calls. It is called
  inside `!$omp parallel` and has no work-sharing, so every thread recomputed
  all boundary faces;
* adds `sensor`, `t` and the module data used inside the loop to `shared` in the
  `default(private)` sensor loops;
* privatises the scratch variables in the monitor integrals. The stack fixed 2 of
  these loops; the same race exists in 5, and all 5 are fixed here.

The `#ifdef _OPENACC` guards the stack wrapped around these were dropped. The
remaining known issue is the shared `pointsToFind` counter in the actuator-line
search (MPI path).

## Test evidence (CPU, gfortran 13, original asserts unless stated)

There is no GPU in this container (no NVIDIA device, no nvfortran), so nothing ran
on GPU. All runs are serial CPU builds.

**Does `ready` change any asserted value?** No. `develop` and `stack-pick/ready`
were run on the same tests:

| Test | develop | ready |
|---|---|---|
| NavierStokes/TaylorGreen | 8/8 pass | 8/8 pass, identical residuals |
| NavierStokes/Cylinder | 9/9 pass | 9/9 pass, identical residuals |
| NavierStokes/LimiterTest | 8/8 pass | 8/8 pass, identical residuals |
| NavierStokes/TaylorGreenSVVLES | 5/8 fail | 5/8 fail, bit-identical values |
| Euler/BoxAroundCircle_pAdapted | segfault while the time integrator is set up | same segfault |

TaylorGreenSVVLES and BoxAroundCircle_pAdapted are only in the old CPU
workflows. Both already fail on `develop`.

**Do the assert-changing commits fail the original asserts?**

| Commit | Test | Result with the original asserts |
|---|---|---|
| Positivity limiter (#115) | LimiterTest | **Fails 7/8** (all residuals, Cd, Cl). It passes only with the author's new values. |
| SVV `divV` fix | TaylorGreenSVVLES on `GMM_develop` | `GMM_develop` **passes 8/8**; with the fix it **fails 5/8** (residuals off by 1e-6 to 1e-3 relative). The failing values match the stack's new reference values, so that part of the stack's assert change is exactly this fix. |
| SVV `divV` fix | TaylorGreenSVVLES on `develop` | No effect: results are bit-identical with and without it, because SVV is never applied on `develop`'s NS path (as noted in `GMM_develop`). |
| MU `"source"` monitor | Multiphase/ActuatorLineInterpolation | Without it the run aborts at start-up (unknown monitor). With it the run completes but **5/10 asserts fail by 1e-10 to 1e-7 relative**, on residuals and forces the monitor cannot affect, so the case looks stale on `develop` (it is commented out in CI). |

So the original asserts encode the current limiter and the current `divV`
expression. Taking either change means either the reference code has the same
bug and both are fixed, or the change is wrong.

## Is every picked commit a real bug fix?

| Commit | Real bug? | How it was established | Changes anything besides the fix |
|---|---|---|---|
| Limiter p(q_avg) | No, the old one is safe but over-limits (one degenerate case fails) | algebra; LimiterTest on CPU | Yes: less dissipation, new reference values |
| `Face_Assign` deep copy | Yes | code path: `coarseSem = sem` then `pAdapt` deallocates aliased face data; no test uses the TE sensor | No |
| NodalStorage mapping | Yes, for meshes with an order above element 1's x-order, on GPU | reading | Also maps unused constructed orders (a little device memory) |
| ActuatorLine guard | Yes | reproduced (segfault) | No |
| Strong-form split fluxes | Yes, for isolated TE with split form | reading; uninitialised arrays | No |
| `exit data delete(sem)` | Not demonstrated | the author says it segfaults; not reproducible here | Housekeeping |
| SVV `divV` (energy gradvars) | Yes | reading | Changes TaylorGreenSVVLES results (not in active CI) |
| TE sensor `x(:,i,j,k)` + `S = 0` | Yes, both | reading; default problem file leaves `S` unset | No |
| TE sensor `pAdapt_MPI` | Yes, per the code's own comment that `pAdapt` does not work with MPI | reading; not run with MPI | No |
| Monitor host refresh | Yes, but only partly fixed | reading | Extra device-to-host copies per monitor evaluation |
| MU `"source"` monitor | No, a feature | n/a | Also adds an early return to a test ProblemFile |
| OpenMP: ActuatorLine construct | Yes | reproduced (develop fails to compile with threads) | Adds `x`, `newPartition` to private (mine, not in stack) |
| OpenMP: boundary flux single, shared lists, privates | Yes, races by OpenMP rules | reading; threaded build compiles | Only for `ENABLE_THREADS=YES` |

## Duplicates

| Stack change | Already in |
|---|---|
| `ViscousFlux_SELECTED`, `NSGradientVariables_SELECTED`, `getVelocityGradients_SELECTED`; use in BCs, LES, BR1/BR2/IP face gradients (#113) | #107: `ViscousFlux_GradVars`, `GradientVariables_Selector`, `getVelocityGradients_selector`. #107 also covers MU/iNS/CH and adds CI regression cases |
| `getVelocityGradients_Entropy` formula fix (#113) | #107 `aac758f6`, `GMM_develop` `7a20f115` (identical formula) |
| Local gradients in selected variables: `HexMesh_ComputeLocalGradientNS` reusing `contravariantFlux` as scratch (#113); `BaseClass_ComputeGradient` allocating per element (#116) | #107 / `arr/missing_terms_grad_vars` (computed inside the elliptic schemes) |
| Artificial viscosity on GPU (#116) | `GMM_develop` `97ce1357` (device kernel `SC_ComputeElementAviscFlux`) |
| Central AviscFlux interior/MPI face term (#116) | `GMM_develop` (same expression) |
| AviscFlux enter/exit data (#116) | `GMM_develop` |
| GMM `maxloc(dim=2)` replacement (#116) | `GMM_develop` `751241b3` |
| Monitor host refresh (#117) | Same problem as the old `TGV-monitor-fix`; the stack's version is better, so it is taken |

## Regressions

* **`#ifdef _OPENACC` / `#ifndef _OPENACC` around `!$acc` and `!$omp` lines**
  (#113, also in #114 and #116: 373 added `#if`/`#else`/`#endif` lines in 12 files). These are dead code:
  `Makefile.in` forces `ENABLE_THREADS:=NO` for nvfortran, so an OpenACC build
  never has OpenMP, and gfortran/ifort treat `!$acc` as a comment. They only
  make the code harder to read and maintain.
* **GPU IBM wall function (#113).** In `IBM_SemiImplicitCorrection` the moved
  `#endif` puts the whole wall-function semi-implicit step in the
  `#ifndef _OPENACC` branch, so GPU builds silently skip it.
* **Reverts of work merged into `main`.** #113/#114 replace #92's fused
  `ScalarWeakIntegrals_SplitVolumeDivergence` with the older fSharp/gSharp/hSharp
  version and re-enable it for INCNS, which #92 disabled on purpose. #113 also
  deletes the #97 GPU performance workflow, the TaylorGreenPerformance case and
  its `configure` entry.
* **`if (Nxyz > 0)` guards inside ACC loops** in
  `HexElement_ComputeLocalGradient` (#113). They are redundant (D is zero for
  N=0) and go against `18427c77`, which removed such checks from ACC loops.
* **Split-form kernel duplicated 7×** through `split_template.inc` (#114), one
  copy per two-point flux. It conflicts with #92, has no benchmark behind it,
  and reads and writes QDot in global memory where #92 accumulates in registers.
* **Host round-trips on every RHS for AV/SVV** (#116). `UpdateHostData` plus
  per-element `update self/device` of QDot and AviscFlux, and SVV/AV computed
  with many small per-element kernels inside host loops with per-element data
  regions. Much slower than `GMM_develop`'s device path.
* **Boundary-face AviscFlux** (#116). It is subtracted after the BC and Jacobian
  scaling, so artificial-viscous flux leaks through adiabatic/free-slip walls.
  `GMM_develop` adds it before `FlowNeumann` for exactly this reason.
* **Reference values (#116).** ForwardFacingStepSVV residuals change by ~3×
  (3594 → 11194, 870 → 5803, …) and TaylorGreenSVVLES by up to 1.7 %, with no
  explanation. ForwardFacingStepSVV uses entropy gradient variables, so the
  `divV` fix does not explain it.

## New, but not mergeable as is

* **Wall distance on GPU** (#114). It opens a data region and launches a kernel
  per element from a host loop. `copyin(self)` is shallow, and on the
  p-adaptation path the mesh is already present, so `copyin` becomes a no-op. It
  also changes `dWall` with no walls from sqrt(huge) to huge, which overflows in
  NSSA's dWall². The idea is good for large wall counts; it needs one kernel over
  all DOFs.
* **SVV on GPU** (#116). `GMM_develop` keeps SVV on the host. The stack's port
  could be a starting point, but it has the per-element launch problem above and
  copies results back to the host anyway.
* **TE sensor on GPU** (#116). It creates device data for the coarse mesh and
  round-trips Q/QDot. It is low priority.

## Neutral / out of scope

* Pointer → `associate` in `SCsensorClass` / `AnalyticalJacobian`; removing
  `impure elemental` from `ElementStorage_InterpolateSolution` (all callers are
  scalar); `!$acc routine seq` additions in `Physics_NSSA`; NSSA aliases in
  `Physics.f90` / `VariableConversion.f90`.
* `AnalyticalJacobian` OpenMP restructuring (implicit CPU solver). Not ported.
* `-cuda` added to `NVFORTRAN_RELEASE_FLAGS` in `utils/ProblemFile/Makefile`.
  Plausible (the solver is built with `-cuda`), but it needs an nvfortran check.

## Side findings (not from the stack)

* `develop`'s `TimeDerivative_VolumetricContribution_Split` loops
  `l = 0..Nxyz(1)` for all three directions, which is wrong for anisotropic
  orders. `main` already fixes this through #92, which is not in `develop`
  (expected with #123).
* `develop` does not compile with `ENABLE_THREADS=YES` (see the OpenMP branch).
* The v1.0 tag could not be pushed to the fork from this session (proxy 403);
  `git push origin v1.0` from a normal clone fixes that.
