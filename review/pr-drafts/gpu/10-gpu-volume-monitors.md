## Compute the volume monitors on the GPU

The volume monitors were computed on the host from copies of `Q`, `QDot` and the gradients that are only updated when a solution file is saved, so on the GPU they were wrong: in `TaylorGreen` the kinetic energy stayed at its initial value, and its rate and the enstrophy were 0. The solution itself was fine.

* `ScalarVolumeIntegral` now runs on the device as one OpenACC reduction, as `VectorVolumeIntegral` already did, and copies back one number per monitor. Monitors without a device version (NS kinetic-energy and entropy balance, acoustic energy) stop the run with a message instead of printing wrong values.
* The `velocity` monitor read its reduction before the kernel had finished (`async(1)`).
* The enstrophy uses `getVelocityGradients_State`, so it needs state gradient variables until the `GMM_develop` PR brings the device selector.

The CPU code is unchanged (all new code is inside `#ifdef _OPENACC`). On the GPU the monitors now match the CPU (e.g. the kinetic-energy rate to 8e-12), and nothing else changes. The `TaylorGreenSVVLES` checks didn't catch this because their tolerance (1e-7) is larger than the values (2e-8).
