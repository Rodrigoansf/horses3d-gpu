# Review brief: rotary (revolution) periodic BCs, by AbbBallout (Abbas)

Twin PRs, one commit each, opened 2026-10-22:
- horses3d-gpu #145 `abbas_developement` -> `develop` (head da89463d). https://github.com/horses-framework/horses3d-gpu/pull/145
- horses3d (legacy CPU) #387 `abbas_developement` -> `master` (head 7d838992). https://github.com/horses-framework/horses3d/pull/387
  Body: "same as #145gpu". Legacy version has no OpenACC and its RotateRotaryFaces{Solution,Gradients}
  take an optional `element_ids(:)` list (legacy prolongs sequential and MPI elements separately).

The user (Rodrigo, horses-framework maintainer) is a reviewer. Questions to answer: is this the right
solution, is it correct, does it affect performance (CPU and GPU), is it necessary, are there
better alternatives, is it maintainable?

## Where the code is (read-only for you)

- GPU PR tree (sparse checkout: everything except Solver/test, plus the new test and Cylinder SETUP/control):
  `/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/rev145`
- Legacy PR tree (same sparse layout): `/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/rev387`
- Full diffs: `design/review-rotary/gpu145.diff`, `design/review-rotary/leg387.diff`
- Bases, as git refs (use `git -C <repo> show <ref>:<path>` / `git -C <repo> grep <pattern> <ref>`):
  - GPU repo `/home/rodrigo/Desktop/Horses3d-Epicure/horses3d-gpu`: PR = `review/pr145`, base = `upstream/develop`
  - Legacy repo `/home/rodrigo/Desktop/Horses3d-Epicure/horses3d`: PR = `review/pr387`, base = `upstream/master`
  - Any file under Solver/test that is not in the sparse trees can be read with `git show review/pr145:Solver/test/...`.
- `design/` paths are relative to `/home/rodrigo/Desktop/Horses3d-Epicure/gpu-wt/`.

## What the PR does (summary)

- `periodic enabled = .true.` + `rotation axis` + `rotation center` in the control file switch ALL
  `Periodic` boundary pairs to rotary matching (by radius and axial coordinate; axis must be x, y or z).
- `ConstructPeriodicFaces` (HexMesh.f90) flags matched faces `isRotaryPeriodic` and computes ONE global
  sector angle from the first matched node pair (`SectorAngle`, atan2 in the plane normal to the axis),
  root rank only; `SyncPeriodicAngle` broadcasts it.
- New module `RotaryFaceRotations` (libs/mesh): after prolongation, the side-2 face state Q(2:4) and the
  side-2 gradients (G <- R G R^T) are rotated into side 1's frame by -angle; the flux FStar(2:4) and
  the gradient flux unStar projected to side 2 are rotated back by +angle. MPI faces: the received side
  is rotated into the local frame (sign by `ReceivedSide`), nothing is rotated back.
- Hooks in SpatialDiscretization (ComputeTimeDerivative, ComputeQDot, ComputeQDotHO), EllipticBR1/BR2/IP,
  DGSEMClass (read params, NS-only check, broadcast angle), MeshPartitioning/partitioned_mesh (flag sent
  to ranks and written to the .partitioning file), FaceClass (new logical component), FluidData (re-exports
  RotationData), new lib `libs/rotation` (RotationData: params, matching helpers, angle), Makefiles.
- Test `NavierStokes/RotaryPeriodic` (120 deg sector around x, annulus r in [1,11], P2, 100 steps,
  8 MPI ranks in CI_parallel_NS only), docs (UserManual.tex + md), unrelated-looking Cylinder.control change.

## Leads from a first read (UNVERIFIED - confirm or refute each with code evidence, then look for more)

1. Single global angle from the first matched pair: (a) if there are several periodic pairs and the
   "master" (zIDPlus, first in zone order) is on the other side for one of them, that pair needs -angle;
   (b) if the first matched node lies on the rotation axis (r=0, e.g. a pipe sector whose periodic faces
   meet at the axis), atan2(0,0) gives angle 0 -> all rotations become identity, silently; (c) no check
   that every matched pair has the same angle.
2. Axis sign: SectorAngle is measured counter-clockwise about the POSITIVE coordinate axis, but the
   rotation matrix uses the signed user axis. `rotation axis = [-1,0,0]` (or [0,0,-1]) may rotate the
   wrong way. (Being tested at runtime by the main session.)
3. `periodic enabled = .true.` with a non-aligned axis silently leaves periodicEnabled false -> falls back
   to translational matching -> cryptic failure. Keyword name is generic. Zero-norm axis -> NaN.
4. CompareTwoNodesRevol(Relax) compares SQUARED radii; the relaxed variant uses a tolerance in units of
   length (min_edge_length) against L^2 quantities.
5. MPI: is the side numbering of an MPI face (HexMesh_UpdateFacesWithPartition) the same as side 1/2 of
   the serial face, so the sign from ReceivedSide matches the angle's orientation? Is the angle correct
   when the partitions are read from a .partitioning file / when root does not run ConstructPeriodicFaces?
   Each rank also runs ConstructPeriodicFaces on its local mesh and may call SetPeriodicAngle again.
6. Coverage of call sites: other paths that prolong to faces / compute face fluxes without rotation
   (isolated / IMEX / linear-nonlinear splits, implicit Jacobians, multigrid/FAS, p-adaptation, HO
   elements: BR2/IP skip the gradient rotation when HOElements is true but still rotate unStar back).
   Anything that reads face storage(2) of an interior face after the in-place rotation and expects
   element-2's frame (sensors, SVV/artificial viscosity, LES/wall models, monitors, statistics)?
7. OpenMP: barriers between prolongation and rotation loops; RotateBackRotaryFacesGradientFlux has no
   explicit barrier; ordering after `!$omp end do nowait` loops.
8. GPU (OpenACC): rotationParams `declare create` + `update device` timing (before device selection?);
   async(1) kernels vs host-side MPI gather; `matmul`, array-valued function, array constructor and
   assumed-shape dummies inside `!$acc routine seq`; kernels loop over ALL elements / ALL interior faces
   to touch a handful of rotary faces. Was it ever compiled with nvfortran? CI is gfortran CPU only.
9. Test: the IC is a Gaussian swirl at 90 deg with sigma 5 deg; periodic faces at 0 and 120 deg (6 sigma
   away) -> the periodic coupling may barely be exercised; monitors named cyl-drag/cyl-lift on a
   FreeSlipWall called "inflow"; cl = -2000.88; tolerance 1e-11; only an 8-rank MPI run in CI (no serial,
   no OpenMP, no GPU). Asserts are regression values only ("no expected solution yet").
10. Design: global switch means translational + rotational periodicity cannot be combined (e.g. annular
    sector that is also periodic axially - a common LES setup). Axis restricted to x/y/z although the
    rotation math is general. FluidData re-exports RotationData everywhere. Node-matching helpers live in a
    new `rotation` lib instead of the mesh lib. .partitioning file format changed (old files unreadable).
    Cylinder.control change looks unrelated. Debug prints in BR2 ("I am in BR2 line 211") - pre-existing?

## Rules

- Read-only: do not build, run the solver, edit sources, commit, push, or post anything to GitHub.
  `gh` read-only queries are fine. The main session runs all builds/tests (one heavy job at a time).
- Cite evidence as `path:line` in the PR tree (rev145 / rev387), or `ref:path:line` for base refs.
- Distinguish: bug in the PR / pre-existing issue / design concern / question for the author.
- Write your full result to the markdown file named in your task, then return the structured output.
