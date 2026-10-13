## Split form: compute the sharp fluxes again (strong-form volume term and aliasing sensor)

**Base:** `develop` · **Branch:** `change/strong-form-split-fluxes` · 2 commits, 2 lines each · GPU-only bug (legacy is correct)

### What happened

In legacy, the split form computes its "sharp" two-point fluxes with a type-bound call:

```fortran
call HyperbolicDiscretization % ComputeSplitFormFluxes(e, F, fSharp, gSharp, hSharp)
```

The GPU port replaced that type-bound procedure with a plain routine, `SplitDG_ComputeSplitFormFluxes`, and updated the main volume term to call it. In two other places the old call was simply commented out, and nothing replaced it:

1. `TimeDerivative_StrongVolumetricContribution` (`SpatialDiscretization.f90`), and
2. `Sensor_aliasing` (`SCsensorClass.f90`).

Both go on to use `fSharp/gSharp/hSharp` (`Fs/Gs/Hs` in the sensor) without ever filling them.

### The fix

In both places, call the new routine, exactly as the main volume term does:

```fortran
call SplitDG_ComputeSplitFormFluxes(e, F, fSharp, gSharp, hSharp)
```

One commit per place: the first is zalbanob's, from #116; the second applies the same fix to the sensor.

### Who is affected

- **Strong-form volume term:** only runs that combine the split form with an *isolated* time derivative. That is the truncation-error estimators: the TE shock sensor with `Sensor TE derivative = isolated`, the TE-based p-adaptation, and multigrid tau estimation. The normal time step doesn't go through this routine.
- **Aliasing sensor:** only `Shock sensor = aliasing error`, which only works with the split form.

So this changes results only where the old results were built on uninitialised memory. It's in its own PR because it does change results there.

### How it was checked

- CPU (gfortran 13): builds; `NavierStokes/Cylinder` 9/9.
- GPU (laptop, earlier run of the first commit together with the minor fixes): 17 single-GPU CI cases bitwise identical to `develop`.
- No test uses either path.
- The aliasing sensor still can't run, in this code or in legacy master. It segfaults on the second element, before it reaches the line fixed here. Its scratch-array allocation logic deallocates `F, Fs, Gs, Hs` when the next element has the same order and never reallocates them. That is a separate bug, shared with legacy, and is not fixed in this PR.

### Notes

`GMM_develop` has the same two commented-out lines. It will get the fix when develop is merged into it.
