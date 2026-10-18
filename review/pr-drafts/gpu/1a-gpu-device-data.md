## GPU device data: every polynomial order on the GPU, every copy released

This PR makes the device data of the mesh complete and balanced: every polynomial order that is used is copied to the GPU and can be used by the kernels, and everything copied in is deleted at the end. It doesn't change any result of a case that runs today, and it makes the cases with more than one polynomial order run on the GPU at all: anisotropic orders, different orders per element, and 2D meshes (`ForwardFacingStepSVV`), which all crashed before. Together the commits remove the device memory `develop` leaves behind at exit (33 MB for `Cylinder`, 2.25 GB for the multiphase `EntropyConservingTest`). Nothing here adds host↔device transfers to the time loop: the changes only touch set-up and shut-down.

**Map every NodalStorage order to the device**. `NodalStorage(N)` holds the quadrature nodes, weights and derivative matrices for polynomial order N. `HexMesh_CreateDeviceData` copied them to the GPU with:

```fortran
DO i = 0, self % Nx(1) !it should be the maximum nX
```

That is the x-order of *element 1*. The comment already says it should be the maximum. If any element uses a higher order (anisotropic orders, or different orders per element), that order is never mapped, and the first kernel that uses it reads a host address. The loop now goes over every order that has actually been constructed. `sharpD` exists only with the split form, so it is mapped only when it is allocated. The exit routine now also deletes `w` and `x`, so that every copy-in is matched by a delete.

**Copy the whole NodalStorage array to the device**. Mapping every order was necessary, but not enough: anisotropic orders still crashed. The reason is how the array was copied. `NodalStorage` is a module pointer array, and the loop above copied it one element at a time:

```fortran
!$acc enter data copyin(NodalStorage(i))
```

Each of these gives one order its own device allocation, and leaves the device pointer `NodalStorage` attached to only one of them. A kernel can then index only that order; any other order reads a garbage descriptor, and the run stops with an illegal or misaligned address. Cases with one polynomial order everywhere worked only because they use just the order that happened to be attached. A 2D mesh is a hidden case of this: HORSES3D sets the order in the offset direction to 0, so `ForwardFacingStepSVV` runs 7×7×0 elements and needs `NodalStorage(0)` as well as `NodalStorage(7)`. `compute-sanitizer` shows it directly: the first thread of `HexElement_ComputeLocalGradient` reads address `0xfffffffffffffff9` on the line that uses `NodalStorage(self % Nxyz(1)) % D`.

The whole array is now copied once, which also attaches the device pointer, and then each constructed order's matrices are attached to it:

```fortran
!$acc enter data copyin(NodalStorage)
DO i = 0, ubound(NodalStorage,1)
   if (.not. NodalStorage(i) % Constructed) cycle
   !$acc enter data copyin(NodalStorage(i) % hatD)
   ...
```

Shut-down deletes the matrices, then the array.

The CPU build of the GPU code is reported to give NaN on p-nonconforming faces, because `Face_AdaptSolToFace` lost the interpolation that legacy has. That is a separate problem and is not touched here.

**Balance enter/exit data in HexMesh**. A device-allocation trace on the laptop GPU found about 7,200 allocations still alive at exit. Going through `CreateDeviceData` and `ExitDeviceData` side by side:
- `elements % geom % x` was copied in twice;
- `S_NS`, `stats`, `geom % x`, `geom % normal`, `isInsideBody`, `STL`, the faces' `rho`, `geom % x`, `geom % h`, the zones and `no_of_elements` were copied in but never deleted.

The duplicate copy-in is removed and the missing deletes are added, so every `enter data` now has a matching `exit data`. At program exit this is harmless, because the CUDA context frees everything anyway. It matters for leak checkers, and for anything that re-creates a mesh on the device inside one run.

**Release `sem` at shut-down**. Both mains do `!$acc enter data copyin(sem)` and never delete it, and the multiphase main never called `ExitDeviceData` at all. The NS main gets the missing delete. The multiphase main gets the same teardown block the NS main already has.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), this branch alone against `develop`:
- The 17 cases of `CI_serial_GPU.yml` plus `TaylorGreenSVVLES` and the three truncation-error scratch cases: bitwise identical to `develop` (residuals and every monitor file), with the same assertion results.
- `Cylinder` runs with one local, uncommitted line in its control file, because on `develop` it crashes on the GPU before the first step (fixed by the ParamfileRegions PR); the line changes no result.
- **Cases with more than one polynomial order**, on `develop` and on this branch, against the CPU build of the same case:

  | case | `develop` (GPU) | this branch (GPU) | GPU vs CPU (gfortran) |
  |---|---|---|---|
  | TaylorGreen 8³, `Polynomial order i/j/k = 3/4/5` (local copy of `NavierStokes/TaylorGreen`, 3 steps) | illegal address | runs | residuals agree to 9e-10 |
  | `NavierStokes/CylinderDifferentOrders` | illegal address | 9/9 | residuals agree to 1.2e-13 |
  | `NavierStokes/ForwardFacingStepSVV` (2D mesh: 7×7×0) | illegal address | runs to the end | — |

  On `develop`, `ForwardFacingStepSVV` then fails 4 of its 6 assertions, because its reference values assume shock capturing, which `develop` does not apply. With the shock-capturing work from `GMM_develop` merged as well (branch `goal/end-goal`) it passes 6/6; before this fix it crashed there too, in `HexMesh_ComputeLocalGradientNS`. (The anisotropic TaylorGreen's volume monitors still differ from the CPU: GPU volume monitors are stale, a separate issue.)
- **Device memory left at exit**, from an `NV_ACC_NOTIFY=16` allocation trace (allocations without a matching free, counted by `gpu-wt/tools/leaks.py`): `Cylinder` 28,482 allocations (33 MB) on `develop` → 18 (0.01 MB, boundary-condition and probe scalars); multiphase `EntropyConservingTest` 1,549,580 allocations (2.25 GB) → 8.

**Not checked:** multi-GPU and MPI. The cluster CI (`CI_parallel_GPU.yml`) should be run before merging.
