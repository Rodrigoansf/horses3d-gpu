## Shock capturing: prolong the artificial viscous flux to the faces on the GPU

Stacked on the `GMM_develop` → `develop` PR (base branch `feat/gmm-shock-capturing`): it only touches the shock-capturing path that PR brings. It removes a CPU round trip from every Runge–Kutta stage of every shock-capturing run, and makes the threaded CPU build of the same code deterministic. On the laptop GPU the shock-capturing test cases give bitwise identical results and run 17–32% faster.

### What happened

With shock capturing on, each evaluation of the right-hand side computed the artificial viscous flux of every element on the GPU, then:
1. copied it to the CPU, one transfer per element (`update self`);
2. interpolated it to the element faces on the CPU (`SC_ProlongAviscFluxToFaces` → `HexElement_ProlongAviscFluxToFaces` → `Face_AdaptAviscFluxToFace`);
3. copied every face back to the GPU, one transfer per face (`update device`).

### What changes

**The interpolation runs on the GPU**, the same way as the solution is sent to the faces (`HexMesh_ProlongSolToFaces`): one loop over (element, face) pairs, where each pair fills its own side of the face. Two new device routines do the work. `HexElement_ProlongAviscToFaces` interpolates the flux component normal to the face to the element boundary, with the outward sign. `Face_AdaptAviscToFace` rotates the result to the face orientation and changes its sign for the right-hand element. They do the same operations in the same order as the host routines, which are kept for the host paths that still use them: the isolated time derivative of the truncation-error sensor, the host fallback of shock capturing, and RANS.

Like the solution and gradient prolongation on the GPU, the new routines handle rotated faces but not faces whose two sides have different polynomial orders: the projection matrices are not on the device.

Copies that remain:
- SVV runs still copy one dissipation value per element back for the volume monitors. With the GPU volume-monitor PR, monitors no longer read it on the host, so this copy can go in a follow-up.
- In MPI runs the face flux exchange is still packed on the CPU. `HexMesh_UpdateMPIFacesAviscFlux` now waits for the GPU and copies back only the local side of each MPI face. The received side is pushed to the GPU as before.

**Share the element loops among OpenMP threads.** `TimeDerivative_ComputeArtificialViscosity` is called by every thread of the parallel region of `ComputeTimeDerivative`, and its element loop and the prolongation had no work-sharing directive: every thread processed every element. For SVV that is a race, because the filter passes use the element's `AviscContravariantFlux` and `SVVdev_W` as scratch. Both loops now use `!$omp do`, like the other element loops. This only changes builds with `ENABLE_THREADS=YES`; it is needed with the first commit, whose device-shaped prolongation uses shared face scratch.

### How it was checked

GPU (RTX 3060 laptop, nvfortran 26.3, one GPU), on `goal/end-goal` with and without these commits, two interleaved runs each, nothing else running:

| case | before | after | results |
|---|---|---|---|
| `CylinderGMM` | 11.8 s | 8.8 s | bitwise identical, 5/5 |
| `TaylorGreenSVVLES` | 8.7 s | 7.3 s | bitwise identical, 8/8 |
| `ForwardFacingStepSVV` | 15.8 s | 10.7 s | bitwise identical, 6/6 |

(wall time, including set-up). The other 18 GPU cases (no shock capturing) are bitwise identical.

CPU (gfortran): serial builds of `goal/end-goal` with and without these commits: `CylinderGMM`, `TaylorGreenSVVLES`, `ForwardFacingStepSVV`, `Cylinder` and `CylinderDifferentOrders` (rotated faces) are bitwise identical. Threaded builds (`ENABLE_THREADS=YES`), 4 threads: shock-capturing runs were wrong before (every case failed its assertions and changed from run to run). Most of that was not this code but the split-form volume loop, which had no `!$omp do` either; that fix is in the OpenMP PR. With both, `CylinderGMM` and `ForwardFacingStepSVV` with 4 threads are bitwise identical to 1 thread and from run to run, and `TaylorGreenSVVLES` passes 8/8 (its near-zero kinetic-energy-rate monitor differs at 1e-16, the order of a sum).

**Not checked:** multi-GPU and MPI (the exchange path changed: one `update self` per MPI face of its local side). The cluster CI should be run before merging.
