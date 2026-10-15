## Aliasing sensor: don't free the scratch arrays when the next element has the same order

This is the GPU twin of the legacy PR of the same name, which explains it step by step. In short, `Sensor_aliasing` keeps its scratch arrays (`F`, `Fs`, `Gs`, `Hs`, `aliasing`) from one element to the next and is meant to reallocate them only when the polynomial order changes. When the order *doesn't* change, it set `need_alloc = .false.` but left `need_dealloc = .true.`. So it freed the arrays and never allocated them again. The next call, `ComputeInnerFluxes(e, EulerFlux, F)`, then got an unallocated `F` and segfaulted.

The fix adds one line:

```fortran
   if (all(ubound(F) == [NCONS, e % Nxyz(1), e % Nxyz(2), e % Nxyz(3), NDIM])) then
      need_alloc = .false.
      need_dealloc = .false.
   end if
```

With a uniform order, the sensor crashed on its second element, so `Shock sensor = aliasing error` could not be used at all.

### Related PR

The aliasing sensor has a second, GPU-only problem: the call that fills `Fs/Gs/Hs` was commented out in the port. That is fixed in the "split form: compute the sharp fluxes again" PR. The two touch different lines and can be merged in any order. The sensor gives meaningful values only once both are in.

### How it was checked

CPU (gfortran 13, serial), on the same small case as the legacy PR: the TaylorGreenSVVLES setup with the split form, `Shock sensor = aliasing error`, P=4 and 3 steps.

| build | result | sensor at steps 1–3 |
|---|---|---|
| split-form PR branch, without this fix | segfault in `ComputeInnerFluxes` before the first step completes | – |
| this branch alone | runs to the end | 1.0 in every element (reads the uninitialised `Fs/Gs/Hs`) |
| this branch + the split-form PR | runs to the end | 0.0 in every element, **same as legacy with its fix** |

Not run on a GPU: the sensor runs on the host.

`GMM_develop` has the same code and will get the fix when develop is merged into it.
