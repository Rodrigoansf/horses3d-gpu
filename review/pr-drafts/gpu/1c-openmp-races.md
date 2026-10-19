## Fix OpenMP races (monitors, boundary faces, split-form volume term)

This PR fixes several races in CPU builds with `ENABLE_THREADS=YES`. nvfortran builds have threads off, so GPU results don't change.

* Monitor integrals: their temporaries (`p`, `tau`, `val`, `local1..local5`) were shared between threads. Cherry-picked from #117, which fixed two of the six loops; the other four are fixed here.
* `computeBoundaryFlux` is called by every thread and its face loops had no `!$omp do`, so every thread computed every boundary face. The loops are now shared, as in legacy (#113 put the whole call under `!$omp single` instead).
* The same problem in `TimeDerivative_VolumetricContribution_Split`: the threads overwrote each other's `QDot`, so every split-form case was wrong with threads (`CylinderKennedyGruberLaxFriedrichs` passed 8/8 with 1 thread and failed 8/8 with 4).

With 4 threads, `Cylinder` and the split-form cylinder cases now give the same residuals as the serial build. Note that `develop` only compiles with `ENABLE_THREADS=YES` after horses-framework/horses3d-gpu#143.
