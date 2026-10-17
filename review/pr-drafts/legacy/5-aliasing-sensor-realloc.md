## Aliasing sensor: don't free the scratch arrays when the next element has the same order

This PR adds one line to the aliasing shock sensor. It fixes a crash and changes nothing else. It's one of five small, independent PRs that came out of reviewing the GPU version of HORSES3D, which has the same code.

### What this code does

`Sensor_aliasing` (in `SCsensorClass.f90`) loops over the elements. For each one it needs a few scratch arrays (`F`, `Fs`, `Gs`, `Hs`, `aliasing`) whose size depends on the element's polynomial order. To avoid allocating them for every element, it keeps them from one element to the next and only reallocates when the order changes:

```fortran
need_dealloc = .true.
need_alloc = .true.
if (allocated(F)) then
   if (all(ubound(F) == [NCONS, e % Nxyz(1), e % Nxyz(2), e % Nxyz(3), NDIM])) then
      need_alloc = .false.          ! same order: keep them...
   end if
else
   need_dealloc = .false.
end if
if (need_dealloc) deallocate(F, ...)  ! ...but they are freed anyway
if (need_alloc)   allocate(F, ...)
```

### The bug

When the order is the same as for the previous element, `need_alloc` becomes `.false.`, but `need_dealloc` stays `.true.`. So the arrays are freed and never allocated again. The very next line, `ComputeInnerFluxes(e, EulerFlux, F)`, then receives an unallocated `F`.

That happens whenever two consecutive elements share an order. With a uniform order, that's every element after the first. So in practice, `Shock sensor = aliasing error` crashes on its second element and can't be used.

### The fix

```fortran
   if (all(ubound(F) == [NCONS, e % Nxyz(1), e % Nxyz(2), e % Nxyz(3), NDIM])) then
      need_alloc = .false.
      need_dealloc = .false.
   end if
```

### Evidence

We used a small case: the TaylorGreenSVVLES setup with the split form, `Shock sensor = aliasing error`, P=4 and 3 steps.

| | result |
|---|---|
| master | segmentation fault inside `ComputeInnerFluxes`, called from `Sensor_aliasing`, before the first time step completes |
| this PR | runs to the end; the sensor is 0 in every element at every step, as expected for this smooth flow |

A `-fcheck` build of the GPU version, which has identical code here, names the problem directly: *"Allocatable actual argument 'f' is not allocated"*.

No existing test uses the aliasing sensor, which is probably why this wasn't noticed.

### How it was checked

- Built with gfortran 13 (`make ns`, serial).
- The run above, on master and on this branch.
- Rebased on master `a01ca08b4`. All 59 Navier–Stokes and multiphase cases of the serial CI workflows were run with gfortran (serial) on master and with all five legacy PRs of this review stacked. 56 give bitwise-identical output; two of those stop on both builds because the test machine has no MKL (`RisingBubble`, multiphase `Convergence`). `TaylorGreenSVVLES` changes, as described in the SVV PR, and passes 8/8 on both sides (old references on master, new ones with the PRs). `CylinderGMM` is not reproducible run to run: one of three runs of the PR build differed, the other two matched master, which gave three identical runs (its asserts pass every time). `VirtualSurfaces_acoustics_pAdaptationRL` needs HDF5, which the test machine doesn't have.
