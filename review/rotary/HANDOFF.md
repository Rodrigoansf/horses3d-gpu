# Handoff: prototype the fixes for the rotary periodic PR

Started in a local session on 22 Oct 2026 (review, validation, report). Continue here in the cloud.
Read `README.md`, then `REVIEW.md` (findings with evidence) and `github-review-draft.md`.

This branch = Abbas's PR head da89463d (horses-framework/horses3d-gpu #145) + this folder.
Legacy twin: horses-framework/horses3d #387, branch `abbas_developement` (Rodrigo's fork: Rodrigoansf/horses3d).

## Task

Prototype fixes for the NS problems, validate them, and show Rodrigo the results (he follows from his
phone, keep messages short). Same fixes in the legacy twin.

1. Axis sign: `SectorAngle` measures about +x/+y/+z but the matrix uses the signed axis. Multiply the
   angle by `sign(1, axis(coord))`. (Verified on the laptop: [-1,0,0] then passes and matches.)
2. Angle handling: replace the logical `isRotaryPeriodic` + one global `periodicAngle` by a signed angle
   per rotary face, computed at matching from the face centroids (never on the axis), sent to the ranks
   and written/read in the .partitioning file like the flag is now. Rotation routines use the face angle
   (MPI faces: received-side sign as now). Fixes: read-partitioning angle 0, node-on-axis angle 0,
   several pairs with opposite masters (zone order is hash order), each rank overwriting the angle.
3. BR2: move `RotateRotaryFacesGradients` to the end of `BR2_ComputeGradient` (after both face-integral
   loops), as BR1 does. Legacy also has the HO-element variant.
4. Input checks: error stop if `periodic enabled` with a zero axis or one not along x, y or z.
5. Matching: compare r, not r²; relaxed tolerance in length units.
6. Rotate-back loops (`RotaryFaceRotations.f90` ~164, ~191): loop over `storage(2) % Nel`, not `Nf`.
7. Legacy only: rotate `storage(2) % AviscFlux(2:4)` of rotary faces before averaging
   (`NavierStokesSolver/SpatialDiscretization.f90:1763`, MPI `:1855`).
8. Legacy only: error stop for rotary periodic + analytical Jacobian.
9. NSSA: not supported for now (Rodrigo's decision). Only make it fail loudly (the NS-only guard in
   `DGSEMClass.f90` also stops when SPALARTALMARAS is defined) and say in the docs that `horses3d.nssa`
   is not supported yet (in progress). Draft a GitHub wiki note too, but do not publish it.

Optional: a list of rotary face IDs built once + rotation applied with scalars (removes the ~2.7% GPU
overhead and the implicit `vrot` copies); a test that loads the coupling (swirl centred on a periodic
face, serial CI run; reference values must be equal to legacy's).

## Validation

Build the CPU code (gfortran; MPI if it can be installed) and rerun `cases/`: sector vs annulus with BR1,
IP and BR2 (BR2 at dt = 3e-4, on legacy: BR2 diverges on GPU develop even without periodic BCs), the
[-1,0,0] axis, the theta-ordered mesh with `read partitioning from files = .true.` (3 and 4 ranks),
serial vs MPI. Correct = probes within ~1e-11 of the annulus. No GPU here: GPU checks need a later run
on Rodrigo's laptop.

## Rules (from Rodrigo)

- Never push to horses-framework. Ask before any commit or push (also to the fork) and before posting
  anything on GitHub (reviews, comments, wiki).
- Commits authored `Rodrigoansf <rodrigoansf@gmail.com>`, no Co-Authored-By line; no Claude footer in
  PR texts. Commit and PR texts short and plain (subject + 1-2 sentences).
- Test reference values stay equal to legacy's; never change them just to make a test pass.
- At most one subagent at a time: wider workflows hit the session usage limit and kill the session.
