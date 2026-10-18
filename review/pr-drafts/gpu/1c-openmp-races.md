## OpenMP: no more data races in the monitors and the boundary loops

These two fixes only matter for CPU builds with `ENABLE_THREADS=YES`; nvfortran builds force threads off, so GPU binaries are unaffected. They fix races that made threaded runs compute wrong monitor values and repeat the boundary work on every thread. A third OpenMP fix, the actuator-line point search (which kept threaded builds from compiling at all), is in the actuator-line PR because it edits the lines next to that PR's other fix.

- **Monitor integrals**. In the surface-force and vector volume-integral loops, scratch variables (`p`, `tau`, `val`, `local1..local5`) were shared between threads. Every thread wrote to the same variables at the same time. They are now private. There are six such loops. The stack fixed two of them (total force and the source integral). This commit also fixes the other four (pressure force, viscous force, velocity and momentum), which had the same race.
- **Boundary-face loops**. `computeBoundaryFlux` is called by every thread inside the parallel region of `ComputeTimeDerivative`. Its face loops had no `!$omp do`, so every thread computed every boundary face. That is the same work repeated *n* times, with all threads writing to the same faces. The loops are now shared out with `!$omp do`, as legacy horses3d does. The per-zone `FlowNeumann` call loops over the zone itself, so it runs under `!$omp single`. (The stack put the whole routine under `!$omp single`. That's correct, but it makes the boundary serial.)

### How it was checked

- Threaded CPU build (gfortran, `ENABLE_THREADS=YES`): `develop` does not compile with `ENABLE_THREADS=YES` (the actuator-line work-sharing construct, fixed in the actuator-line PR), so the threaded runs use `develop` plus this PR plus the actuator-line PR. `NavierStokes/Cylinder` passes 10/10 with 1 and with 4 threads. With 1 thread it is bitwise identical to the sequential build of `develop`. With 4 threads the residuals are still bitwise identical; the surface monitors differ only by the order of the sum over threads (drag 6e-16 relative; lift 2e-10 relative, on a lift of 6e-6, so about 1e-15 absolute).
- GPU (RTX 3060 laptop, nvfortran 26.3), this branch alone against `develop`: the 17 cases of `CI_serial_GPU.yml`, `TaylorGreenSVVLES` and the three truncation-error scratch cases are bitwise identical (nvfortran builds have threads off, so nothing here can change a GPU result).

**Not checked:** multi-GPU and MPI. The cluster CI (`CI_parallel_GPU.yml`) should be run before merging.
