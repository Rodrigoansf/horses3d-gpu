## develop: minor fixes from the review of the stack PRs

This PR collects the small fixes for `develop` that came out of reviewing the five stack PRs (horses-framework/horses3d-gpu#113 to horses-framework/horses3d-gpu#117). None of them changes results in a case that runs today. They fix crashes, memory problems and OpenMP races, or they release GPU memory that was never freed. The changes that *do* change results have their own PRs: "split form: compute the sharp fluxes again", "positivity limiter", "SVV divV" and "TE sensor source term".

Each commit stands on its own and has a full explanation in its message, so the easiest way to review is commit by commit. Below is the slow version, grouped by topic.

Nothing here adds host↔device transfers to the time loop. The GPU changes only touch set-up and shut-down.

---

### 1. GPU device data (3 commits)

**Map every NodalStorage order to the device**. `NodalStorage(N)` holds the quadrature nodes, weights and derivative matrices for polynomial order N. `HexMesh_CreateDeviceData` copied them to the GPU with:

```fortran
DO i = 0, self % Nx(1) !it should be the maximum nX
```

That is the x-order of *element 1*. The comment already says it should be the maximum. If any element uses a higher order (anisotropic orders, or different orders per element), that order is never mapped, and the first kernel that uses it reads a host address. The loop now goes over every order that has actually been constructed. `sharpD` exists only with the split form, so it is mapped only when it is allocated. The exit routine now also deletes `w` and `x`, so that every copy-in is matched by a delete.

Caveat: on its own, this doesn't make anisotropic orders work on the GPU. The laptop GPU run found a second, separate crash in `HexMesh_ProlongSolToFaces`. It also found that the CPU build of the GPU code gives NaN on p-nonconforming faces, because `Face_AdaptSolToFace` lost the interpolation that legacy has. Those are tracked separately. This commit only removes one of the obstacles.

**Balance enter/exit data in HexMesh**. A device-allocation trace on the laptop GPU found about 7,200 allocations still alive at exit. Going through `CreateDeviceData` and `ExitDeviceData` side by side:
- `elements % geom % x` was copied in twice;
- `S_NS`, `stats`, `geom % x`, `geom % normal`, `isInsideBody`, `STL`, the faces' `rho`, `geom % x`, `geom % h`, the zones and `no_of_elements` were copied in but never deleted.

The duplicate copy-in is removed and the missing deletes are added, so every `enter data` now has a matching `exit data`. At program exit this is harmless, because the CUDA context frees everything anyway. It matters for leak checkers, and for anything that re-creates a mesh on the device inside one run.

**Release `sem` at shut-down**. Both mains do `!$acc enter data copyin(sem)` and never delete it, and the multiphase main never called `ExitDeviceData` at all. The NS main gets the missing delete. The multiphase main gets the same teardown block the NS main already has.

### 2. `Face_Assign` aliased instead of copying (1 commit)

`Face_Assign` (`FaceClass.f90`) is the `=` operator for faces. It did this:

```fortran
allocate(to % geom)
to % geom => from % geom        ! the new allocation is lost, and both faces now share one geom
```

So `copy = original` didn't copy anything: both faces pointed to the same geometry and storage. The truncation-error sensor relies on this copy when it builds its coarse mesh with `coarseSem = sem`, and then lowers the coarse mesh's polynomial order. Because of the alias, it reallocated face data that the fine mesh was still using. The fix assigns the contents instead (`to % geom = from % geom`).

### 3. OpenMP, CPU builds only (3 commits)

These three only matter with `ENABLE_THREADS=YES`. nvfortran builds force threads off, so the GPU binaries are unaffected.

- **Actuator-line point search**. An `!$omp do` was closed about 80 lines after the end of its loop. It also listed `Q` and `Qtemp` as private, but those variables no longer exist, so `ENABLE_THREADS=YES` didn't compile at all. The construct is now closed right after the loop, with the right private list.
- **Monitor integrals**. In the surface-force and vector volume-integral loops, scratch variables (`p`, `tau`, `val`, `local1..local5`) were shared between threads. Every thread wrote to the same variables at the same time. They are now private. There are six such loops. The stack fixed two of them (total force and the source integral). This commit also fixes the other four (pressure force, viscous force, velocity and momentum), which had the same race.
- **Boundary-face loops**. `computeBoundaryFlux` is called by every thread inside the parallel region of `ComputeTimeDerivative`. Its face loops had no `!$omp do`, so every thread computed every boundary face. That is the same work repeated *n* times, with all threads writing to the same faces. The loops are now shared out with `!$omp do`, as legacy horses3d does. The per-zone `FlowNeumann` call loops over the zone itself, so it runs under `!$omp single`. (The stack put the whole routine under `!$omp single`. That's correct, but it makes the boundary serial.)

### 4. Truncation-error sensor: MPI and OpenMP (2 commits)

These two are the same as in the legacy horses3d "minor fixes" PR, which has the same bugs and a fuller explanation.

- **MPI: build the coarse mesh with `pAdapt_MPI`**. The sensor lowers the order of its coarse mesh with `HexMesh_pAdapt`, whose own comment says *"this one does not work with MPI"*. In MPI runs it now uses `pAdapt_MPI`, as the RL p-adaptation does. Serial runs are unchanged.
- **OpenMP: complete two `shared(...)` lists**. Two loops in `SCsensorClass.f90` use `default(private)` but don't list everything they read: `sensor`, `t`, `NodalStorage`, `thermodynamics`, `dimensionless` and `refValues`. Each thread then gets uninitialised copies. This only matters with `ENABLE_THREADS=YES`, which nvfortran builds don't use.

In legacy, with a 2-rank MPI run and a 4-thread run of a small truncation-error case, master segfaults and the fixed branch runs to the end; the 4-thread residuals are bit-identical to the serial ones.

### 5. Actuator line: unallocated array (1 commit)

`newPointToFind` is only allocated in MPI runs, but it was set to zero on every call. In a serial run that's an assignment to an unallocated array. It's now guarded with `if (allocated(...))`.

### 6. Multiphase "source" volume monitor (1 commit)

Legacy horses3d's multiphase solver accepts a `source` volume monitor, but the GPU port lost it. As a result, the multiphase `ActuatorLineInterpolation` control file, which is identical to legacy's, is rejected at start-up. The integral it needs (`SOURCE`) is already compiled for multiphase; this commit wires it back into the monitor, as legacy does.

---

### How it was checked

**CPU (gfortran 13), this branch on the previous `develop` (before horses-framework/horses3d-gpu#119 added a tenth assert to `Cylinder`), serial:**
- `make ns mu` builds.
- `NavierStokes/Cylinder` 9/9 and `Multiphase/EntropyConservingTest` 5/5.
- `Multiphase/ActuatorLineInterpolation` used to stop at start-up because of the missing monitor. It now runs to the end. 5 of its 10 asserts miss by 1e-9 to 1e-7 relative. That case is commented out of both MU CI workflows on develop, so this PR doesn't try to fix it.

The threaded build, and Cylinder with 4 threads, were checked on the earlier combined branch with the same OpenMP commits.

**GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), this branch against `develop`:**
- The 17 cases of `CI_serial_GPU.yml` plus `TaylorGreenSVVLES`: every monitor file is **bitwise identical** to `develop`, and every case passes the same asserts.
- `Cylinder` was run with one local, uncommitted line added to its control file, because on `develop` it now crashes on the GPU before the first step (see the "ParamfileRegions" PR). The line gives monitor 3 a `Reference surface`, which only lift and drag use, so it changes no result; with the ParamfileRegions fix the unmodified file gives bitwise the same output.
- **Device memory left at exit**, from an `NV_ACC_NOTIFY=16` allocation trace (allocations without a matching free). Measured with all six review PRs stacked; only this one touches device allocation:

  | case | `develop` | with this PR |
  |---|---|---|
  | `NavierStokes/Cylinder` | 28,482 allocations, 33 MB | 18 allocations, 0.01 MB |
  | `Multiphase/EntropyConservingTest` | 1,549,580 allocations, 2.25 GB | 8 allocations, 0.00 MB |

  The few that remain are small boundary-condition and probe buffers created outside the mesh.
- **Truncation-error sensor**: on `develop`, a run with `Shock sensor = truncation error` stops at once with `cuMemAlloc ... CUDA_ERROR_INVALID_VALUE` (the `Face_Assign` alias). With this branch the small TE cases in `review/scratch-cases` (`te.control`, `te-std.control`) run to the end on the GPU.
- Speed: with all six review PRs stacked, each case was run interleaved with `develop`, twice, with nothing else on the machine. In the second repetition, with the laptop GPU at a steady temperature, every case is within ±0.5% of `develop`'s solver efficiency (median ratio 0.999). The first repetition scatters by up to ±30% in both directions while the GPU heats up and throttles.

**Not checked:** multi-GPU. The cluster CI (`CI_parallel_GPU.yml`) should be run on this branch before merging.
