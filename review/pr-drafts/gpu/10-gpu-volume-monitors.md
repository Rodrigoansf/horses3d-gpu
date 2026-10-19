## GPU: compute the scalar volume monitors on the device

On the GPU, most volume monitors print wrong numbers. In `TaylorGreen` the kinetic energy stays at its initial value, and the kinetic-energy rate and the enstrophy are 0 at every iteration. The solution itself is right; only the monitors are wrong. This PR computes them on the GPU, where the data is, and copies back one number per monitor and time step. It changes nothing on the CPU, and nothing in the solution, residuals, surface monitors or probes on the GPU.

### What happened

The scalar volume integrals behind the volume monitors (`ScalarVolumeIntegral` in `VolumeIntegrals.f90`) were never ported: they loop over the elements on the host and read the host copies of `Q`, `QDot` and the gradients. On the GPU those host copies are only refreshed when a solution file is saved (`HexMesh_UpdateHostData`), and `QDot` is never copied back. So the monitors read the initial condition (kinetic energy), zero (`QDot`: the kinetic-energy rate) or gradients that were never computed on the host (enstrophy). The vector integrals (`VectorVolumeIntegral`) and the residuals were already computed on the device.

### What changes

**Scalar volume monitors on the device.** In GPU builds `ScalarVolumeIntegral` calls a new `ScalarVolumeIntegral_Device`, one OpenACC kernel with a reduction over elements and nodes, as `VectorVolumeIntegral` does. The integrand at each node is a new `!$acc routine seq` function, `ScalarVolumeIntegrand`, with the formulas of `ScalarVolumeIntegral_Local` written node by node. Ported: kinetic energy and its rate, mean velocity, entropy, mathematical entropy, entropy rate, internal energy and artificial (SVV) dissipation for Navier–Stokes; mass, entropy, kinetic-energy rate and entropy rate for incompressible NS; entropy rate, entropy balance and the phase-2 area, centre of gravity and velocity for multiphase; free energy for Cahn–Hilliard. The volume only needs the geometry and stays on the host. The integrals without a device version (kinetic-energy balance and entropy balance for Navier–Stokes, acoustic energy) now stop the run at the first monitor update with a message, instead of printing stale values.

**Wait for the velocity monitor's reduction.** `VectorVolumeIntegral` ran the "velocity" reduction with `async(1)` and read the result straight away. With `async` the result of a reduction is only defined after the queue has finished. It now runs synchronously, like the momentum and source monitors.

**Enstrophy on the device.** The velocity gradients come from the stored gradients with `getVelocityGradients_State`. That covers state gradient variables, the default and what the TaylorGreen cases use. With `Gradient variables = entropy` or `energy` the run stops with a message; the device selector for those comes with the `GMM_develop` PR, and with both merged the enstrophy works for all three (tested on `goal/end-goal`).

All the new code is inside `#ifdef _OPENACC`. The code gfortran compiles is identical before and after: stripping the `_OPENACC` blocks and `!$acc` lines from `VolumeIntegrals.f90` gives the same 529 lines, including the 10 OpenMP directives. So CPU results are bitwise identical by construction.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU):
- This branch alone against `develop`: the 17 cases of `CI_serial_GPU.yml` (`Cylinder` with the one local control-file line, see the ParamfileRegions PR) plus `TaylorGreenSVVLES`: residuals, surface monitors and probes bitwise identical, same assertion results. Only `TaylorGreenSVVLES` has volume monitors of the ported kinds, and they now move: its kinetic energy, which stayed at the initial 0.12499999999999917 at every step, now evolves, and its kinetic-energy rate is no longer 0 (its SVV dissipation stays 0, because `develop` doesn't apply shock capturing). `NavierStokes/TaylorGreen` on the 8³ mesh (P = 3, 3 steps; the 32³ case does not fit in the laptop GPU's 6 GB): kinetic energy, kinetic-energy rate and enstrophy match the CPU (gfortran) run to 4e-15, 8e-12 and 6e-15.
- On `goal/end-goal` (every PR merged, with the shock-capturing work from `GMM_develop`), with and without these commits, 23 cases: residuals, surface monitors and probes bitwise identical, same assertion results. The volume monitors now match the CPU (gfortran) runs of the same case: anisotropic TaylorGreen (orders 3/4/5) kinetic energy and enstrophy to 1e-14, kinetic-energy rate to 7.5e-12 (before: frozen, 0 and 0); `TaylorGreenSVVLES` kinetic energy to 5e-14 and SVV dissipation to 5e-13.

**For the team:** the `TaylorGreenSVVLES` volume-monitor assertions cannot see this bug. They test the kinetic-energy rate and the SVV dissipation as `value + 1.0` with a tolerance of `1e-7`, which is effectively an absolute `1e-7` on values of `2e-8`, so 0 passes. Tighter assertions are a test change, left to you.

**Not checked:** multi-GPU and MPI (the reduction is followed by the existing `MPI_Allreduce`, unchanged).
