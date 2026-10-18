## Truncation-error sensor: make it run (GPU, MPI, OpenMP)

On `develop` the truncation-error shock sensor can't run: on the GPU it stops at once with `cuMemAlloc ... CUDA_ERROR_INVALID_VALUE`, in MPI runs it builds its coarse mesh with a routine that doesn't support MPI, and with OpenMP threads two of its loops read uninitialised copies. This PR fixes the three, without changing any result of a case that runs today. The fix that changes the sensor's values (the source term) is a separate PR and needs this one to run.

### `Face_Assign` aliased instead of copying

`Face_Assign` (`FaceClass.f90`) is the `=` operator for faces. It did this:

```fortran
allocate(to % geom)
to % geom => from % geom        ! the new allocation is lost, and both faces now share one geom
```

So `copy = original` didn't copy anything: both faces pointed to the same geometry and storage. The truncation-error sensor relies on this copy when it builds its coarse mesh with `coarseSem = sem`, and then lowers the coarse mesh's polynomial order. Because of the alias, it reallocated face data that the fine mesh was still using. The fix assigns the contents instead (`to % geom = from % geom`).

### MPI and OpenMP

These two are the same as in the legacy horses3d "minor fixes" PR, which has the same bugs and a fuller explanation.

- **MPI: build the coarse mesh with `pAdapt_MPI`**. The sensor lowers the order of its coarse mesh with `HexMesh_pAdapt`, whose own comment says *"this one does not work with MPI"*. In MPI runs it now uses `pAdapt_MPI`, as the RL p-adaptation does. Serial runs are unchanged.
- **OpenMP: complete two `shared(...)` lists**. Two loops in `SCsensorClass.f90` use `default(private)` but don't list everything they read: `sensor`, `t`, `NodalStorage`, `thermodynamics`, `dimensionless` and `refValues`. Each thread then gets uninitialised copies. This only matters with `ENABLE_THREADS=YES`, which nvfortran builds don't use.

In legacy, with a 2-rank MPI run and a 4-thread run of a small truncation-error case, master segfaults and the fixed branch runs to the end; the 4-thread residuals are bit-identical to the serial ones.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), this branch alone against `develop`:
- The 17 cases of `CI_serial_GPU.yml` plus `TaylorGreenSVVLES`: bitwise identical to `develop` (residuals and every monitor file), with the same assertion results. None of them uses the truncation-error sensor.
- `Cylinder` runs with one local, uncommitted line in its control file, because on `develop` it crashes on the GPU before the first step (fixed by the ParamfileRegions PR); the line changes no result.
- The small TE cases in `review/scratch-cases`: on `develop` the two truncation-error cases (`te.control`, `te-std.control`) stop before the first step with `cuMemAlloc ... CUDA_ERROR_INVALID_VALUE`; on this branch both run to the end. The third case (`te-alias.control`) uses the aliasing sensor, and segfaults on `develop` and on this branch alike: that is the aliasing sensor's scratch-array bug, fixed in its own PR (with that PR it runs to the end).

**Not checked:** multi-GPU and MPI. The cluster CI (`CI_parallel_GPU.yml`) should be run before merging.
