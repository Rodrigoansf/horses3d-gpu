## Actuator line: serial guard, threaded build, multiphase "source" monitor

Three fixes that make the actuator-line cases run again, in serial runs, threaded CPU builds and the multiphase solver. None changes a result of a case that runs today.

### Serial runs: unallocated array

`newPointToFind` is only allocated in MPI runs, but it was set to zero on every call. In a serial run that's an assignment to an unallocated array. It's now guarded with `if (allocated(...))`.

### Threaded builds: the point-search work-sharing construct

**Actuator-line point search**. An `!$omp do` was closed about 80 lines after the end of its loop. It also listed `Q` and `Qtemp` as private, but those variables no longer exist, so `ENABLE_THREADS=YES` didn't compile at all. The construct is now closed right after the loop, with the right private list.

### Multiphase "source" volume monitor

Legacy horses3d's multiphase solver accepts a `source` volume monitor, but the GPU port lost it. As a result, the multiphase `ActuatorLineInterpolation` control file, which is identical to legacy's, is rejected at start-up. The integral it needs (`SOURCE`) is already compiled for multiphase; this commit wires it back into the monitor, as legacy does.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), this branch alone against `develop`:
- The 17 cases of `CI_serial_GPU.yml` plus `TaylorGreenSVVLES`: bitwise identical to `develop` (residuals and every monitor file), with the same assertion results.
- `Cylinder` runs with one local, uncommitted line in its control file, because on `develop` it crashes on the GPU before the first step (fixed by the ParamfileRegions PR); the line changes no result.
- `NavierStokes/ActuatorLineInterpolation`: 10/10 on `develop` and on this branch, bitwise identical.
- `Multiphase/ActuatorLineInterpolation`: on `develop` the control file is rejected at start-up (no `source` volume monitor). On this branch it runs to the end on the GPU and on the CPU (gfortran), and the two agree to 2e-12. Five of its ten assertions fail on both: the residuals and the `source` integral differ from the expected values by 1e-11 to 1.4e-7 (relative), for example X-momentum residual 67.848885049539 against 67.848885010292. The expected values are legacy horses3d's (legacy master passes 10/10 with the identical control file), so the multiphase solver of horses3d-gpu differs slightly from legacy's in this case. That difference is older than this PR, which only makes the case run. **Question for the team:** update this test's reference values to horses3d-gpu's own, or first find where the multiphase solver departs from legacy?
- Threaded CPU build (gfortran, `ENABLE_THREADS=YES`): `develop` does not compile (`Unexpected !$OMP END DO statement`, and `q`, `qtemp` have no implicit type, in `ActuatorLine.f90`); `develop` plus this branch and the OpenMP PR compiles. See the OpenMP PR for the threaded runs.

**Not checked:** multi-GPU and MPI. The cluster CI (`CI_parallel_GPU.yml`) should be run before merging.
