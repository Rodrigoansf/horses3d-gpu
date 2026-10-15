## Truncation-error sensor: call the source term with the right point and a clean S

This is the GPU twin of the legacy PR of the same name, which has the full explanation and the evidence. In short, `Sensor_truncation` calls the user source term at every node of the coarse element like this:

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

- CPU (gfortran 13): builds.
- No test uses the truncation-error sensor. On `GMM_develop` the TE sensor can't run at all yet: it segfaults at the first time step because of the Face_Assign aliasing bug, which is fixed in the GMM minor-fixes PR. With that PR, a small TE case runs. So **merge the minor-fixes PR first**. This PR stays separate because it changes results.
