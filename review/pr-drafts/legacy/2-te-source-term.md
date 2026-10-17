## Truncation-error sensor: call the source term with the right point and a clean S

This PR changes two lines in the truncation-error shock sensor. No existing test changes, because no test uses this sensor. It's one of five small, independent PRs that came out of reviewing the GPU version of HORSES3D.

### What this code does

When the shock sensor is `truncation error`, `Sensor_truncation` (in `SCsensorClass.f90`) estimates the truncation error of each element on a coarser copy of the mesh. At every node of a coarse element it needs the user's source term, so it calls:

```fortran
call UserDefinedSourceTermNS(ce % geom % x, ce % storage % Q(:,i,j,k), t, S, &
                             thermodynamics, dimensionless, refValues)
```

and then adds `S` into the truncation-error estimate.

### Two problems with that call

**1. Every node gets the coordinates of the first node.** The source-term routine expects `x(NDIM)`, the coordinates of one point. The call passes `ce % geom % x`, the coordinates of the whole element. Fortran accepts this without a warning, because it simply passes the start of the array. The routine only reads the first three numbers, which are the coordinates of node (0,0,0). Every other call in the code passes `x(:,i,j,k)`. That includes the very similar loop in `TruncationErrorClass.f90`, which is used for p-adaptation.

**2. `S` is never set before the call.** `S` is a local array in `Sensor_truncation`, and nothing initialises it. The source-term routine declares `S` as `intent(inout)` and is allowed to leave it unchanged. Many problem files do exactly that. The default problem file never writes to `S`. Searching `Solver/test` for any assignment to `S` inside `UserDefinedSourceTermNS` finds none in 54 of the 91 problem files. In all those cases, the truncation-error estimate adds whatever happened to be in that memory.

Everywhere else, `S` starts from zero:
- the compressible solver's `S_NS` storage is zeroed when it is allocated;
- the incompressible, acoustic and multiphase solvers set `S_NS = 0` before every call;
- `TruncationErrorClass` sets `S = 0` before its loop.

### The fix

```fortran
S = 0.0_RP
call UserDefinedSourceTermNS(ce % geom % x(:,i,j,k), ce % storage % Q(:,i,j,k), t, S, &
                             thermodynamics, dimensionless, refValues)
```

`S` is reset at every node, not once per element. A problem file is allowed to add to `S` rather than overwrite it.

### Does it matter in practice?

It depends on what happens to be in memory, which is why it's easy to miss. In a normal build on our machine the leftover values happened to be zero, and the sensor looked fine. To make the problem visible, we built master and this branch with `-finit-real=inf`, which fills uninitialised reals with +infinity. We then ran a small case with uniform flow, where the truncation error should be essentially zero. It is the TaylorGreenSVVLES setup with `Shock sensor = truncation error`, P=4, 3 steps and the default problem file.

| | sensor min | sensor max |
|---|---|---|
| master | 1.0 | 1.0 (every element flagged) |
| this PR | 0.0 | 0.0 |

So with unlucky memory contents, the sensor flags the whole domain.

We didn't build a case for the coordinate bug. It only matters for source terms that depend on position, and it's visible directly in the code.

### Something we noticed but didn't change

`TruncationErrorClass` (p-adaptation) sets `S = 0` once, before an OpenMP loop that lists `S` as `private`. In threaded builds, each thread gets its own uninitialised copy, so the zero doesn't reach the threads. With `S` reset inside the loop, as in this PR, that problem would go away too. It's a different module, though, so we left it for a separate change.

### Related PR

In OpenMP builds, this loop also had some variables that were private and uninitialised. That is fixed in the "make it run with MPI and with OpenMP" PR. The two PRs touch different lines and can be merged in any order.

### How it was checked

- Built with gfortran 13 (`make ns`, serial), plus the `-finit-real=inf` builds above.
- No existing test uses the truncation-error sensor, so no tests change. It would be worth adding one.
- Rebased on master `a01ca08b4`. All 59 Navier–Stokes and multiphase cases of the serial CI workflows were run with gfortran (serial) on master and with all five legacy PRs of this review stacked. 56 are bitwise identical. `TaylorGreenSVVLES` changes, as described in the SVV PR, and passes 8/8 on both sides (old references on master, new ones with the PRs). `CylinderGMM` can't be compared: on master itself, the same binary gives different residuals from one run to the next (its asserts pass every time). `VirtualSurfaces_acoustics_pAdaptationRL` needs HDF5, which the test machine doesn't have.
