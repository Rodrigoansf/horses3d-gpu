## Truncation-error sensor: make it run with MPI and with OpenMP

This PR fixes two crashes in the truncation-error (TE) shock sensor, one with MPI and one with OpenMP. In setups that already run, nothing changes: serial runs give the same results. It's one of five small, independent PRs that came out of reviewing the GPU version of HORSES3D. Three of the others change results; the fourth fixes a crash in a different sensor. Each is kept separate so it can be discussed on its own.

There are two commits, one per fix. Both touch only `SCsensorClass.f90`.

---

### 1. MPI: build the coarse mesh with `pAdapt_MPI`

**What this code does.** To estimate the truncation error, the sensor needs a coarser copy of the mesh. `Construct_TEsensor` copies the mesh and lowers the polynomial order of every element with:

```fortran
call sensor % TEestim % coarseSem % mesh % pAdapt(N, controlVariables)
```

**The problem.** Two routines change polynomial orders on a mesh:

- `HexMesh_pAdapt` only rebuilds what changed, so it's faster. Its own comment in `HexMesh.f90` says: *"Optimized version of HexMesh_Adapt_MPI, but this one does not work with MPI"*.
- `HexMesh_pAdapt_MPI` rebuilds everything and handles MPI.

The sensor always calls the first one, even in MPI runs. The RL p-adaptation, by contrast, always calls `pAdapt_MPI`.

**The fix.**

```fortran
!     pAdapt does not work with MPI (see HexMesh_pAdapt)
      if (MPI_Process % doMPIAction) then
         call sensor % TEestim % coarseSem % mesh % pAdapt_MPI(N, controlVariables)
      else
         call sensor % TEestim % coarseSem % mesh % pAdapt(N, controlVariables)
      end if
```

Serial runs keep the faster routine and behave exactly as before. We could instead call `pAdapt_MPI` always, as the RL p-adaptation does. That would be shorter, but serial runs would then rebuild the whole coarse mesh and could change slightly. This code runs only once, at start-up, so speed isn't the issue; we chose the version that leaves serial runs alone.

---

### 2. OpenMP: share the sensor and module data in two loops

This one only affects builds with `ENABLE_THREADS=YES`.

**Background: `default(private)`.** Many loops in `SCsensorClass.f90` start with:

```fortran
!$omp parallel do default(private) shared(...)
```

`default(private)` means that every variable used inside the loop and *not* listed in `shared(...)` gets a fresh, **uninitialised** copy in each thread. That includes the routine's arguments and module variables such as `NodalStorage` or `thermodynamics`. If one of them is left out of the `shared` list, each thread reads garbage instead of the real value, and the compiler gives no warning.

The other loops in this file list what they need, for example `shared(sem, sensor, NodalStorage)`. Two loops don't:

**Sensor inertia, in `Compute_SCsensor`.** This loop reads `sensor % min_steps`, but only `sem` is shared:

```fortran
!$omp parallel do default(private) shared(sem)               ! before
!$omp parallel do default(private) shared(sem, sensor)       ! after
```

This loop is used by every sensor type, not only the TE one, whenever `Sensor min. timesteps` is larger than 1.

**Maximum truncation error, in `Sensor_truncation`.** This loop reads `sensor` (in `SinRamp(sensor, ...)`), the time `t`, and the module variables `NodalStorage`, `thermodynamics`, `dimensionless` and `refValues`. Only `sem` and `csem` are shared:

```fortran
!$omp parallel do default(private) shared(sem, csem)                     ! before
!$omp parallel do default(private) shared(sem, csem, sensor, t, NodalStorage, &
                                          thermodynamics, dimensionless, refValues)   ! after
```

(This is a single line in the code; it's split here only to make it easier to read.)

We checked the other `default(private)` loops in the file, and they already list everything they use.

We didn't switch to `default(none)`, which would make the compiler reject any variable that isn't listed. It's safer, but nothing else in the code base uses it (there are 23 `default(private)` loops), so we stayed with the existing style.

---

### Evidence

We used a small case: the TaylorGreenSVVLES setup with `Shock sensor = truncation error`, `Sensor min. timesteps = 3`, P=4 and 3 time steps. For the MPI runs we added `partitioning = SFC`, because our build doesn't have METIS. Everything was built with gfortran 13 and OpenMPI 4.1.

| build | master | this PR |
|---|---|---|
| serial | runs | runs, identical residuals |
| MPI, 2 ranks (`COMM=PARALLEL`) | segmentation fault while the shock-capturing sensor is being built | runs to the end |
| OpenMP, 4 threads (`ENABLE_THREADS=YES`) | segmentation fault before the first time step completes | runs to the end; residuals bit-identical to the serial run |

No existing test uses the truncation-error sensor, which is probably why neither crash was noticed. It would be worth adding a small test for it, possibly in a separate PR.

### Related PR

The same truncation-error loop also calls the user source term with the wrong point and an uninitialised `S`. That fix changes results, so it is in its own PR ("call the source term with the right point and a clean S"). The two PRs touch different lines and can be merged in any order.

### How it was checked

- Built serial, MPI and threaded with gfortran 13.
- The three runs in the table above.
