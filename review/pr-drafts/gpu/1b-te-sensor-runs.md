## Fix the truncation-error sensor on GPU, MPI and OpenMP

The truncation-error shock sensor could not run on `develop`: on the GPU it stops at start-up (`cuMemAlloc ... CUDA_ERROR_INVALID_VALUE`), with MPI it builds its coarse mesh with a routine that does not support MPI, and with OpenMP two loops read uninitialised variables. The three fixes are cherry-picked from #113 and #116:

* `Face_Assign` allocated `to%geom` and `to%storage` and then pointed them to the source, so the copy `coarseSem = sem` shared its face data with the fine mesh.
* The coarse mesh is built with `pAdapt_MPI` in MPI runs, as the RL p-adaptation does.
* Missing variables in the `shared` lists of the two `default(private)` loops in `SCsensorClass`.

No results change, and the truncation-error cases now run on the GPU. Legacy has the last two bugs too (fixed in its own PR).
