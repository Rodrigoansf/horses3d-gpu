You are working on a local machine with one NVIDIA GPU (compute capability 8.6) and the NVIDIA HPC SDK (nvfortran). The project is HORSES3D-GPU, a high-order DG CFD solver. Fork: https://github.com/Rodrigoansf/horses3d-gpu (upstream: https://github.com/horses-framework/horses3d-gpu).

Your job is to run single-GPU tests that a cloud session without a GPU could not run, and to write up the results. Never push to horses-framework/horses3d-gpu. The only thing you may push is a new branch `review/gpu-results` on the Rodrigoansf fork.

## Setup

1. Record `nvidia-smi` and `nvfortran --version`.
2. Fetch these fork branches and give each its own git worktree, so builds don't interfere:
   - `develop`
   - `fix/gpu-port-develop`
   - `GMM_develop`
   - `fix/gpu-port-GMM`
   - `discuss/legacy-shared-bugs`
3. In each worktree, compile for cc86 only. Edit `Solver/Makefile.in` locally: in `NVFORTRAN_RELEASE_FLAGS`, replace `cc70,cc75,cc80,cc89,cc90` with `cc86` and keep the other `-gpu=` sub-options. Don't commit this edit. Then build:

   ```
   cd Solver && ./configure && make ns mu COMPILER=nvfortran COMM=SERIAL ENABLE_THREADS=NO
   ```

4. Build each test's problem file in its `SETUP` directory with `make COMPILER=nvfortran`. If building all targets fails on a physics you don't need, build only the ns or mu library target.
5. Single GPU only. If a case needs MPI or more than one GPU, skip it and list it in the report.
6. For CPU reference runs, use gfortran: `make ns mu COMPILER=gfortran COMM=SEQUENTIAL ENABLE_THREADS=NO`.

## Tests

### A. No regressions: `fix/gpu-port-develop` against `develop`

Run every NS and MU case that is not commented out in `.github/workflows/CI_serial_GPU.yml`, on both branches. For each case and branch, record:
- assert pass/fail count,
- the last residual line,
- the "Solver efficiency" line,
- wall time.

Expected: identical asserts and residuals (bitwise, or within the test's tolerance), and the same efficiency within run-to-run noise. The branch changes:
- `Face_Assign`,
- NodalStorage device mapping,
- the ActuatorLine guard,
- strong-form split fluxes,
- OpenMP-only edits,
- a multiphase `"source"` volume monitor.

None of these should change a GPU result.

### B. NodalStorage device mapping

This tests the commit "Map every constructed NodalStorage order to the device". On `develop`, only polynomial orders up to the x-order of element 1 are copied to the GPU.

1. Copy `NavierStokes/TaylorGreen`, or `NavierStokes/Cylinder` if TaylorGreen has no boundaries worth testing.
2. Replace `Polynomial order = N` with these three lines (the same keys `NavierStokes/CylinderAnisFAS` uses):
   ```
   Polynomial order i = 3
   Polynomial order j = 4
   Polynomial order k = 5
   ```
3. Run it on the GPU with `develop` and with `fix/gpu-port-develop`, and on the CPU as a reference.

Expected: `develop` crashes or deviates from the CPU run, and the fix branch matches the CPU to round-off. Report the residual histories.

### C. Device copy of `sem` at shutdown

`Solver/src/NavierStokesSolver/main.f90` does `!$acc enter data copyin(sem)` and never deletes it.

1. On `develop`, run a short test and check whether the end of the run (after "I delete the data from the GPU") crashes or reports errors.
2. If `compute-sanitizer --tool memcheck` is available, run it once on a short case.
3. Add `!$acc exit data delete(sem)` right after `call sem % mesh % ExitDeviceData()` and repeat.

Report whether the line is needed. Don't commit it.

### D. Stale monitors on GPU

`NavierStokes/TaylorGreen` has kinetic energy, kinetic-energy rate and enstrophy volume monitors. `ScalarVolumeIntegral` in `Solver/src/libs/monitors/VolumeIntegrals.f90` runs on the host. Reading the code suggests host Q and QDot are only refreshed from the GPU when a solution file is saved (`HexMesh_UpdateHostData`), so these monitors would be stale between saves.

1. Run TaylorGreen on the GPU (`develop`) and on the CPU (same branch).
2. Compare the monitor output in `RESULTS/` iteration by iteration.
3. Work out which iteration the test's asserts read. They use `monitors % volumeMonitors(i) % values(1,1)` in `SETUP/ProblemFile.f90`; the buffer logic is in `Solver/src/libs/monitors/Monitors.f90`.

Report whether the GPU monitors are stale, and whether the current asserts would notice.

### E. GMM branches

1. On `GMM_develop` and on `fix/gpu-port-GMM`, run every shock-capturing case that `GMM_develop`'s `CI_serial_GPU.yml` runs, plus `NavierStokes/TaylorGreenSVVLES`. Expected: identical results.
2. Run `NavierStokes/TaylorGreenSVVLES` on `discuss/legacy-shared-bugs`. On CPU this fails 5 of 8 asserts by design: the SVV `divV` index fix changes the solution, and legacy horses3d changes the same way.
3. Report whether the GPU reproduces the CPU numbers on both branches. CPU reference values:
   - `GMM_develop` passes 8/8.
   - `discuss` gets x-momentum residual 0.12704234777396151 and energy residual 0.62824891369909053.

### F. LimiterTest

Run `NavierStokes/LimiterTest` on `develop` on the GPU. Record pass/fail and the residuals, for information only.

## Report

1. Create branch `review/gpu-results` from `fix/gpu-port-develop`.
2. Write `review/gpu-results-cc86.md` with:
   - hardware and compiler versions,
   - anything unexpected, at the top,
   - one table per section A–F.
3. Revert the `Makefile.in` edit before committing.
4. Push only `review/gpu-results` to the fork (`origin` = Rodrigoansf).
