## develop: minor fixes from the review of the stack PRs

**Base:** `develop` · **Branch:** `fix/minor-develop` · 9 commits

This PR collects the small fixes for `develop` that came out of reviewing the five stack PRs (#113–#117). None of them changes results in a case that runs today. They fix crashes, memory problems and OpenMP races, or they release GPU memory that was never freed. The two changes that *do* change results have their own PRs: "split form: compute the sharp fluxes again" and "positivity limiter".

Each commit stands on its own and has a full explanation in its message, so the easiest way to review is commit by commit. Below is the slow version, grouped by topic.

Nothing here adds host↔device transfers to the time loop. The GPU changes only touch set-up and shut-down.

---

### 1. GPU device data (3 commits)

**Map every NodalStorage order to the device** (`bd1c0a37`). `NodalStorage(N)` holds the quadrature nodes, weights and derivative matrices for polynomial order N. `HexMesh_CreateDeviceData` copied them to the GPU with:

```fortran
DO i = 0, self % Nx(1) !it should be the maximum nX
```

That is the x-order of *element 1*. The comment already says it should be the maximum. If any element uses a higher order (anisotropic orders, or different orders per element), that order is never mapped, and the first kernel that uses it reads a host address. The loop now goes over every order that has actually been constructed. `sharpD` exists only with the split form, so it is mapped only when it is allocated. The exit routine now also deletes `w` and `x`, so that every copy-in is matched by a delete.

Caveat: on its own, this doesn't make anisotropic orders work on the GPU. The laptop GPU run found a second, separate crash in `HexMesh_ProlongSolToFaces`. It also found that the CPU build of the GPU code gives NaN on p-nonconforming faces, because `Face_AdaptSolToFace` lost the interpolation that legacy has. Those are tracked separately. This commit only removes one of the obstacles.

**Balance enter/exit data in HexMesh** (`b5ebff3b`). A device-allocation trace on the laptop GPU found about 7,200 allocations still alive at exit. Going through `CreateDeviceData` and `ExitDeviceData` side by side:
- `elements % geom % x` was copied in twice;
- `S_NS`, `stats`, `geom % x`, `geom % normal`, `isInsideBody`, `STL`, the faces' `rho`, `geom % x`, `geom % h`, the zones and `no_of_elements` were copied in but never deleted.

The duplicate copy-in is removed and the missing deletes are added, so every `enter data` now has a matching `exit data`. At program exit this is harmless, because the CUDA context frees everything anyway. It matters for leak checkers, and for anything that re-creates a mesh on the device inside one run.

**Release `sem` at shut-down** (`9da7daa6`). Both mains do `!$acc enter data copyin(sem)` and never delete it, and the multiphase main never called `ExitDeviceData` at all. The NS main gets the missing delete. The multiphase main gets the same teardown block the NS main already has.

### 2. `Face_Assign` aliased instead of copying (1 commit)

`Face_Assign` (`FaceClass.f90`) is the `=` operator for faces. It did this:

```fortran
allocate(to % geom)
to % geom => from % geom        ! the new allocation is lost, and both faces now share one geom
```

So `copy = original` didn't copy anything: both faces pointed to the same geometry and storage. The truncation-error sensor relies on this copy when it builds its coarse mesh with `coarseSem = sem`, and then lowers the coarse mesh's polynomial order. Because of the alias, it reallocated face data that the fine mesh was still using. The fix assigns the contents instead (`to % geom = from % geom`).

### 3. OpenMP, CPU builds only (3 commits)

These three only matter with `ENABLE_THREADS=YES`. nvfortran builds force threads off, so the GPU binaries are unaffected.

- **Actuator-line point search** (`25447e75`). An `!$omp do` was closed about 80 lines after the end of its loop. It also listed `Q` and `Qtemp` as private, but those variables no longer exist, so `ENABLE_THREADS=YES` didn't compile at all. The construct is now closed right after the loop, with the right private list.
- **Monitor integrals** (`5aa1d97b`). In the surface-force and vector volume-integral loops, scratch variables (`p`, `tau`, `val`, `local1..local5`) were shared between threads. Every thread wrote to the same variables at the same time. They are now private. There are six such loops. The stack fixed two of them (total force and the source integral). This commit also fixes the other four (pressure force, viscous force, velocity and momentum), which had the same race.
- **Boundary-face loops** (`448cfb1b`). `computeBoundaryFlux` is called by every thread inside the parallel region of `ComputeTimeDerivative`. Its face loops had no `!$omp do`, so every thread computed every boundary face. That is the same work repeated *n* times, with all threads writing to the same faces. The loops are now shared out with `!$omp do`, as legacy horses3d does. The per-zone `FlowNeumann` call loops over the zone itself, so it runs under `!$omp single`. (The stack put the whole routine under `!$omp single`. That's correct, but it makes the boundary serial.)

### 4. Actuator line: unallocated array (1 commit)

`newPointToFind` is only allocated in MPI runs, but it was set to zero on every call (`c315bd79`). In a serial run that's an assignment to an unallocated array. It's now guarded with `if (allocated(...))`.

### 5. Multiphase "source" volume monitor (1 commit)

Legacy horses3d's multiphase solver accepts a `source` volume monitor, but the GPU port lost it (`6a03d76b`). As a result, the multiphase `ActuatorLineInterpolation` control file, which is identical to legacy's, is rejected at start-up. The integral it needs (`SOURCE`) is already compiled for multiphase; this commit wires it back into the monitor, as legacy does.

---

### How it was checked

**CPU (gfortran 13), this branch, serial:**
- `make ns mu` builds.
- `NavierStokes/Cylinder` 9/9 and `Multiphase/EntropyConservingTest` 5/5.
- `Multiphase/ActuatorLineInterpolation` used to stop at start-up because of the missing monitor. It now runs to the end. 5 of its 10 asserts miss by 1e-9 to 1e-7 relative. That case is commented out of both MU CI workflows on develop, so this PR doesn't try to fix it.

The threaded build, and Cylinder with 4 threads, were checked on the earlier combined branch with the same OpenMP commits.

**GPU (RTX 3060 laptop, nvfortran 26.3).** These commits were run earlier on the previous `develop` (`ca6f0bd2`), together with the strong-form change. All 17 single-GPU CI cases gave output bitwise identical to `develop`, at the same speed within noise. The two device-data commits were written after that run and have not been run on a GPU yet. They are on the list for the next laptop run, together with a leak check.

**Not checked:** multi-GPU. The cluster CI (`CI_parallel_GPU.yml`) should be run on this branch before merging.
