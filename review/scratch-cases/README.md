# Scratch cases used as evidence in the PRs

None of these is a CI test. Replace `HORSES_ROOT` with the path of the clone you run, then run from an empty folder with `RESULTS/` and `MESH/` subfolders, using the solver's default problem file:

```
mkdir -p run/RESULTS run/MESH && cp te.control run/ && cd run
<clone>/Solver/bin/horses3d.ns te.control
```

| File | Case | Used for |
|---|---|---|
| `te.control` | TaylorGreenSVVLES setup, split form, `Shock sensor = truncation error`, `Sensor TE derivative = isolated`, `Sensor min. timesteps = 3`, P=4, 3 steps, extra `sensor range` volume monitor | TE sensor PRs (MPI, OpenMP, source term) |
| `te-std.control` | same, standard DG instead of split form | TE source term on GMM_develop without the split-form fix |
| `te-alias.control` | same, `Shock sensor = aliasing error` | aliasing sensor PRs |
| `limiter-mach3-cylinder.control` | the GPU `LimiterTest` control (Mach 3 cylinder, P=3, SSPRK33, `Limiter minimum = 1e-5`, 100 steps) | limiter PRs, run on legacy |

Notes:
- MPI builds without METIS need `partitioning = SFC` added to the control file.
- The TE sensor needs the `Face_Assign` fix (`fix/minor-*`) to run at all on horses3d-gpu.
- To expose uninitialised memory, build with `-finit-real=inf` added to `GNU_RELEASE_FLAGS` in `Solver/Makefile.in` (NaN-init doesn't work: `max()` swallows NaN).
