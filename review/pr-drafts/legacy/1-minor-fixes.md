## Fix the truncation-error sensor with MPI and OpenMP

Two fixes for the truncation-error sensor (the same bugs are in horses3d-gpu, fixed in horses-framework/horses3d-gpu#141):

* The coarse mesh is built with `pAdapt_MPI` in MPI runs. `HexMesh_pAdapt` does not work with MPI, and a 2-rank run segfaulted while building the sensor.
* Missing variables in the `shared` lists of the two `default(private)` loops in `SCsensorClass`; a 4-thread run segfaulted.

Both runs now finish, and the 4-thread residuals are the same as the serial ones. No test uses this sensor.
