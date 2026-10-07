# Next GPU tasks for the laptop session (round 2)

Read this file from the fork. Work in tandem with the cloud session:
- The cloud session has no GPU, but it can push to Rodrigoansf/horses3d-gpu. It writes fixes and these task files.
- You run things on the GPU and debug.

How to work:
- You cannot push. Send results and any patch (as a diff) back to the cloud session the same way you sent the cc86 report: a cross-session message. This session's name is `user-5a`.
- Never push anywhere and never touch horses-framework.
- Keep the setup from round 1: separate worktrees, the cc86-only `Makefile.in` edit (not committed), `TMPDIR=/dev/shm` for linking, and rests between runs to cool the GPU.

## 1. Check the new commits (do this first, about 30 min)

Pull these branches:

| Branch | New commits |
|---|---|
| `fix/gpu-port-develop` | `9ede54cf`: balance enter/exit data in `HexMesh_CreateDeviceData` / `ExitDeviceData` |
| | `2aaafaa5`: `exit data delete(sem)` in the NS main; `ExitDeviceData` + `delete(sem)` in the multiphase main |
| `fix/gpu-port-GMM` | `e3f117f0`: `make mu` compiles again (`HexMesh_ComputeLocalGradientNS` falls back to Q outside NS) |

Then:

**a) `fix/gpu-port-develop`:**
1. Re-run section A's 17 cases once. Expect bitwise the same as round 1.
2. Re-run C's TaylorGreen8 2-step case with `NV_ACC_NOTIFY=16`. Report how many device allocations are still alive at exit; round 1 had 7188. The target is about 0. List anything left.
3. Run one multiphase case (`Multiphase/EntropyConservingTest`) to the end. Check that the new multiphase teardown exits cleanly with code 0.

**b) `fix/gpu-port-GMM`:**
1. `make mu` with nvfortran. It should build now.
2. Run `Multiphase/EntropyConservingTest`. On CPU it passes 5/5.

## 2. Root-cause the two GPU crashes (as much time as you can give it)

Send a diagnosis plus a candidate patch as a diff; the cloud session commits and pushes it.

**A. Anisotropic orders on `fix/gpu-port-develop`.**
- The crash: `Polynomial order i/j/k = 3/4/5` on TaylorGreen8 hits an illegal address in `HexMesh_ProlongSolToFaces` (`HexMesh.f90:986`). The CPU build of the same code runs fine.
- Suspects: anything sized with `Nx(1)` or a single N on the device. Places to check:
  - face storage/arrays allocated with `Nf` versus the element's `Nxyz`;
  - `NodalStorage(N) % v` / `b` used per direction in `HexElement_ProlongSolToFaces`;
  - the `present(self)` deep copy of per-element arrays.
- Try 3/3/4 and 4/3/3 to see which direction breaks it.

**B. `ForwardFacingStepSVV` on `GMM_develop`.**
- The crash: illegal address in `HexMesh_ComputeLocalGradientNS` (`HexMesh.f90:5716`). The case is P=7 with `Sensor variable = grad rho`.
- Check:
  - whether `Q_grad_NS` is mapped for every element;
  - whether the element sizes match after any p-change;
  - whether `HexElement_ComputeLocalGradient`'s private arrays overflow at P=7 (gang/vector private sizes, `maxregcount`).
- Does P=5 run?

Do NOT spend time on SVV-on-device or the monitors. Those need design decisions first.

## 3. Reply

Send one message with:
- **Section 1 table:** branch / case / result / allocations alive at exit.
- **Section 2:** what you found and any patch (diff), with evidence (`CUDA_LAUNCH_BLOCKING=1 NV_ACC_NOTIFY=1` output, which variant runs and which crashes).
- **Anything unexpected.**
