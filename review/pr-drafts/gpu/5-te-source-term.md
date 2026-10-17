## Truncation-error sensor: call the source term with the right point and a clean S

This is the GPU twin of the legacy PR of the same name, which has the full explanation and the evidence. It targets `develop`; `GMM_develop` already has it. In short, `Sensor_truncation` calls the user source term at every node of the coarse element like this:

```fortran
call UserDefinedSourceTermNS(ce % geom % x, ce % storage % Q(:,i,j,k), t, S, ...)
```

That has two problems:
1. It passes the whole coordinate array, so every node gets the coordinates of node (0,0,0).
2. `S` is never initialised. The default problem file, and most test problem files, never write to it.

The fix:

```fortran
S = 0.0_RP
call UserDefinedSourceTermNS(ce % geom % x(:,i,j,k), ce % storage % Q(:,i,j,k), t, S, ...)
```

In legacy, a build that fills uninitialised memory with +infinity shows the effect clearly. On a uniform flow, the sensor flags every element before the fix and none after it.

### How it was checked

- CPU (gfortran): builds.
- No test uses the truncation-error sensor. On `develop` the TE sensor can't run at all yet: on the GPU it stops at once with `cuMemAlloc ... CUDA_ERROR_INVALID_VALUE`, because of the `Face_Assign` aliasing bug fixed in the develop minor-fixes PR. So **merge the minor-fixes PR first**. This PR stays separate because it changes results.
- GPU, with all review PRs stacked: the small TE cases in `review/scratch-cases` (`te.control`, split form; `te-std.control`, standard DG) run to the end, and the sensor and monitors agree with the CPU build to round-off (sensor 0.0 in every element at steps 1–3 on both).
- GPU, this branch alone against `develop`: the 18 cases of the GPU CI list plus `TaylorGreenSVVLES` are bitwise identical (none uses the TE sensor); the TE scratch cases still stop at once without the minor-fixes PR, as on `develop`.
