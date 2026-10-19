## Shock capturing and gradient variables on the GPU (GMM_develop)

This PR brings the `GMM_develop` work to `develop`. On `develop`, shock capturing is read from the control file but has no effect: the artificial viscosity is computed nowhere in the time step.

* Shock capturing runs on the device: the methods are flattened into module variables and dispatched with `select case`, and the artificial viscous flux enters the volume, face and boundary terms. SVV, the last method left on the host, now also runs on the device.
* Gradient variables (state, energy, entropy) are dispatched on the device, with fixes to the velocity gradients from entropy variables, the LES models and horses2plt.
* GMM sensor: workaround for an nvfortran `maxloc` bug that aborted every GPU run, and deterministic initial centroids.
* nvfortran fixes: missing `acc routine` for `GuermondPopovFlux_ENTROPY`, and an internal compiler error in MPI builds of HexMesh.

Cases without shock capturing are unchanged on GPU and CPU (including the horses2plt and mergeStatistics CI). With shock capturing, `TaylorGreenSVVLES` goes from 3/8 to 8/8 on the GPU and `CylinderGMM` passes; `ForwardFacingStepSVV` also needs the GPU device-data PR. Not tested with MPI yet.
