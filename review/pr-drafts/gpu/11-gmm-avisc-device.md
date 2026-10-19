## Shock capturing: prolong the artificial viscous flux to the faces on the GPU

Builds on the `GMM_develop` PR. With shock capturing, every Runge–Kutta stage copied the artificial viscous flux of every element to the host, interpolated it to the faces there, and copied every face back.

* The interpolation now runs on the device, like `HexMesh_ProlongSolToFaces`. The host routines are kept for the paths that still use them (isolated time derivative, host fallback, RANS).
* The element loop and the prolongation are now shared between OpenMP threads. Before, every thread processed every element, which is a race for SVV.

Results are unchanged on CPU and GPU, and the shock-capturing cases run 17–32% faster on the GPU (`CylinderGMM` 11.8 → 8.8 s, `ForwardFacingStepSVV` 15.8 → 10.7 s). In MPI runs the face exchange is still packed on the host; not tested with MPI yet.
