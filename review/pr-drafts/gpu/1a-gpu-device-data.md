## Fix the GPU device data: cases with several polynomial orders, and leaks at exit

This PR fixes the device copy of the mesh data. Every case with more than one polynomial order (anisotropic orders, different orders per element, 2D meshes) crashed on the GPU, and part of the device memory was never freed (33 MB for `Cylinder`, 2.25 GB for the multiphase `EntropyConservingTest`). No results change.

* `NodalStorage` was only mapped up to the x-order of element 1 (cherry-picked from #113), and it was copied one order at a time, which leaves the device pointer attached to only one of them. It is now copied as a whole, and every constructed order is attached to it.
* Every `enter data` in `HexMesh_CreateDeviceData` now has a matching `exit data` (`geom%x` was also copied twice).
* `sem` is released at the end of the NS main, and the multiphase main now calls `ExitDeviceData`.

Tested on the GPU: the GPU CI cases are unchanged; `ForwardFacingStepSVV` (a 2D mesh), `CylinderDifferentOrders` and a TaylorGreen with orders 3/4/5 crashed on `develop` and now run and match the CPU. Not tested with MPI yet.
