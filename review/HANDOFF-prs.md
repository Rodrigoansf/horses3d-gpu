# Handoff: upstream bug-fix PRs (19 Oct 2026)

This chat owns the 15 bug-fix PRs open in horses-framework, their fork twins and fork #14.

Another chat owns the GMM work (`HANDOFF-gmm.md`). Leave its branches and worktrees alone:
- branches: fork #13, `feat/gmm-avisc-device`, `GMM_develop`, `goal/end-goal`;
- worktrees: `gpu-wt/gmm`, `gwork`, `dev-pr` and `cpu-new`.

General rules and setup are in `HANDOFF.md`, and the branch history is in `STATUS.md` §0.

## The open PRs

Every upstream branch started as a copy of its fork branch.

**Five upstream branches are now one commit ahead of their fork.** On 19 Oct, between 16:00 and 16:05, the user applied Copilot Autofix suggestions in the GitHub UI:

| PR | Commit | Message | Change |
|---|---|---|---|
| #137 | 82c9557e | "Refactor pressure average calculation for clarity" | `pavg` with the three squares written out |
| #139 | 1c162822 | "Add error handling for integer parameter parsing" | `error stop` when `io > 0`, in the integer routine only |
| #140 | 6175dec0 | "Apply batched suggestions from code review" | the `NodalStorage` loops start at `lbound`, and the two `storage(i)%rho` deletes are moved above the `storage` delete. **Not tested on the GPU.** |
| #141 | 9a3df00f | "Potential fix for pull request finding" | `Face_Assign` allocates `size(from%storage)`, plus a reallocate branch that never runs |
| #143 | f1f1d100 | "Potential fix for pull request finding" | help text `* source` |

What this means:
- These commits have the GitHub noreply author and a `Co-authored-by: Copilot Autofix powered by AI` trailer, which breaks the commit rule below.
- The fork branches don't have them. A plain push from a fork branch is rejected as non-fast-forward, and a force push would delete the user's commits. **Never force-push over them.**
- The CI of these five PRs runs on the autofix heads.

**First, run `git -C horses3d-gpu fetch upstream`.** Then propose, per PR, one of two things and ask the user:
- keep the autofix commit, and fast-forward the fork branch to `upstream/bug-fix-*`; or
- fold it into a proper commit, which needs a force-push upstream and the user's go.

The other ten PRs are still identical to their fork twins: #134, #135, #136, #138, #142, and all five legacy PRs.

**horses-framework/horses3d-gpu → `develop`**

| Upstream | Branch | Fork PR (branch) | Draft |
|---|---|---|---|
| #134 | `bug-fix-split-form-sharp-fluxes` | #3 (`change/strong-form-split-fluxes`) | `pr-drafts/gpu/3-*` |
| #135 | `bug-fix-svv-energy-divv` | #4 (`change/svv-energy-divv`) | `gpu/4-*` |
| #136 | `bug-fix-te-sensor-source-term` | #5 (`change/te-sensor-source-term`) | `gpu/5-*` |
| #137 | `bug-fix-limiter-pressure-reference` | #6 (`change/limiter-pressure-reference`) | `gpu/6-*` |
| #138 | `bug-fix-aliasing-sensor-realloc` | #7 (`fix/aliasing-sensor-realloc`) | `gpu/7-*` |
| #139 | `bug-fix-paramfile-regions-dealloc` | #8 (`fix/paramfile-scalar-dealloc`) | `gpu/8-*` |
| #140 | `bug-fix-gpu-device-data` | #9 (`feat/gpu-device-data`) | `gpu/1a-*` |
| #141 | `bug-fix-te-sensor-gpu-mpi-openmp` | #10 (`feat/te-sensor-runs`) | `gpu/1b-*` |
| #142 | `bug-fix-openmp-races` | #11 (`feat/openmp-races`) | `gpu/1c-*` |
| #143 | `bug-fix-actuator-line` | #12 (`feat/actuator-line`) | `gpu/1d-*` |

**horses-framework/horses3d (legacy) → `master`.** The fork PRs target `upstream-master` (the fork's copy of upstream master, a01ca08b4). The fork's own `master` is the user's MMS branch (#349): never use it as a base.

| Upstream | Branch | Fork PR (branch) | GPU twin |
|---|---|---|---|
| #381 | `bug-fix-te-sensor-mpi-openmp` | #1 (`legacy/minor-fixes`) | #141 (sensor part only) |
| #382 | `bug-fix-te-sensor-source-term` | #2 (`legacy/te-sensor-source-term`) | #136 |
| #383 | `bug-fix-svv-energy-divv` | #3 (`legacy/svv-energy-divv`) | #135 |
| #384 | `bug-fix-limiter-pressure-reference` | #4 (`legacy/limiter-pressure-reference`) | #137 |
| #385 | `bug-fix-aliasing-sensor-realloc` | #5 (`legacy/aliasing-sensor-realloc`) | #138 |

Not ours, leave alone: horses3d #349 and horses3d-gpu #88 (the user's older PRs).

## Rules specific to this chat

**Pushing to horses-framework** needs the user's explicit go for that push. Push by URL, since the `upstream` push URL is disabled on purpose. Both kinds of push must be fast-forwards: check `git log <branch>..upstream/<bug-fix>` and the reverse first.
- GPU:
  ```
  git -C horses3d-gpu push git@github.com:horses-framework/horses3d-gpu.git <branch>:refs/heads/<bug-fix-…>
  ```
- Legacy (same pattern, with the mapping above):
  ```
  git -C horses3d push git@github.com:horses-framework/horses3d.git legacy/<x>:refs/heads/<bug-fix-…>
  ```

**Posting on GitHub** is posting as the user. That covers review replies, PR comments, resolving threads, and editing an upstream PR's title or body. Draft the text, show it, and post only after a yes.

**Commits:** author `Rodrigoansf <rodrigoansf@gmail.com>`, with no Claude or Copilot lines. Messages are in amrueda's style: a subject plus 1–2 plain sentences. The user's example: "This changes the average pressure from the limiter to be the pressure of the average state rather than the average nodal pressure to match X paper."

**PR text:** 1–3 sentences, a few bullets, and one test line.
- `gpu-wt/tools/restyle_prs.py` holds every PR body and the real upstream numbers. Every run rewrites all the drafts in `pr-drafts/`, and `--push` PATCHes every fork PR it lists.
- That list includes the GMM chat's entries: fork #13 (draft `gpu/9-*`) and the AV branch (draft `gpu/11-*`). Restrict a run to this chat's entries (fork #3–#12, #14 and legacy #1–#5), or the GMM chat's edits get reverted.
- It never touches the upstream bodies; those are edited by hand, after a yes.

**Review page:** https://claude.ai/artifact/Fh6MnLe4vCiGxCmnNsP85D, built by `gpu-wt/tools/make_review_page.py <data dir> <out.html>`. Its data dir is gone. To rebuild it:
1. `gh pr list -R Rodrigoansf/horses3d-gpu --state all --limit 50 --json number,state,url,title,body,headRefName,baseRefName,additions,deletions,changedFiles > D/fork-horses3d-gpu.json`.
2. The same for `Rodrigoansf/horses3d`, into `D/fork-horses3d.json`.
3. The same fields for `gh pr list -R horses-framework/horses3d-gpu --author zalbanob --state all`, into `D/stack.json`.
4. `echo '{}' > D/commits.json`.
5. Republish to the same URL.

## Copilot review comments (first task)

Copilot left 18 inline comments, on nine of the GPU PRs:
- #136 has no review: the request failed because the requester's Copilot quota was used up.
- The legacy PRs were not reviewed.
- GitHub marks seven of the comments outdated, because the autofix commits above already acted on them.

Commands:
- full text: `gh api repos/horses-framework/horses3d-gpu/pulls/<n>/comments`;
- reply in a thread: `gh api repos/horses-framework/horses3d-gpu/pulls/<n>/comments/<id>/replies -f body=…`.

The rows marked "checked" were verified against the code (on the fork branches, and on the upstream heads where an autofix exists). Match legacy unless legacy is wrong.

| PR | Comment id | Where | Copilot says | State and first read |
|---|---|---|---|---|
| #134 | 4312725550, 4312725644 | `SCsensorClass.f90:895, 960` | import `SplitDG_ComputeSplitFormFluxes` from `HyperbolicSplitForm`, as `SpatialDiscretization` does | **Checked.** Style only. Legacy has no import to match: it calls the type-bound `HyperbolicDiscretization % ComputeSplitFormFluxes` (legacy `SCsensorClass.f90:960`), which the GPU port commented out (`HyperbolicSplitForm.f90:23`). Either import from `HyperbolicSplitForm` like `SpatialDiscretization.f90:1208` (2 lines), or reply that `HyperbolicDiscretizations` re-exports it. |
| #135 | 4312727484 | `SVV.f90:668` | `divV` is a momentum divergence | **Checked, wrong.** The line is `Hx(IRHOU)+Hy(IRHOV)+Hz(IRHOW)`. With energy gradient variables (rho, u, v, w, T; `VariableConversion_NS.f90:263-267`), slots 2–4 hold u, v, w, so this is sqrt_mu·div(u). Reply. |
| #135 | 4312727551 | TaylorGreenSVVLES `ProblemFile.f90:554` | add a manufactured-state test for `divV` | Team's call. Reply. |
| #137 | 4312725427 | `ExplicitMethods.f90:1202` | rename `pavg`, its comment is misleading | Open. Legacy #384 has the same name and comment (`ExplicitMethods.f90:1818-1820`); if renamed, do both. |
| #137 | 4312725483 | `ExplicitMethods.f90:1203` | `sum(qavg(2:4)**2)` makes a temporary | **Done by autofix 82c9557e** (squares written out). Legacy #384 already writes them out. Keep (sync fork #6) or revert. |
| #138 | 4312723630 | `SCsensorClass.f90:942` | add a regression test for the aliasing sensor | Open. `review/scratch-cases/te-alias.control` could become one. Ask the user. |
| #139 | 4312725773 | `ParamfileRegions.f90:148` | when `io > 0` (read error), the undefined `val` is still assigned | **Half done by autofix 1c162822**: `error stop` in the integer routine only; the real and logical routines still assign the undefined `val`. develop and legacy keep `var` allocated with whatever the failed read left, with no error. Make the three routines consistent (allocate only when `io == 0`; on `io > 0` either `error stop` in all three or leave `var` unallocated). Ask the user which, then sync fork #8. |
| #139 | 4312725872 | `ParamfileRegions.f90:142` | the comment block is repeated in the three routines | Valid. Shorten it to one line, which fits the short style. |
| #140 | 4312729486, 4312729622 | `HexMesh.f90:4599, 4770` | loop from `lbound(NodalStorage,1)`, not 0 | **Checked, not needed** (allocated `(0:Nmax)`, `NodalStorageClass.f90:88/95`). Autofix 6175dec0 applied it anyway, which is harmless. Keep or revert; reply either way. |
| #140 | 4312729571 | `HexMesh.f90:4720` | `storage` is deleted before `storage(1)%rho` and `storage(2)%rho` | **Checked, valid** (51e5e45b added the `rho` deletes after the parent delete). Autofix 6175dec0 moved them above it, **untested**. Test upstream's head on the GPU (see Tests), then reply and sync fork #9. |
| #141 | 4312725935 | `FaceClass.f90:1054` | `allocate(to%storage(2))` assumes two sides | **Checked.** Every face has two sides (legacy: fixed `storage(2)`, `FaceClass.f90:80`; GPU: always `allocate(f % storage(2))`). Autofix 9a3df00f switched to `size(from%storage)` and added a reallocate branch that never runs. Keep, cut to the one-line allocate, or revert and reply; then sync fork #10. |
| #142 | 4312760907 | `SpatialDiscretization.f90:1381` | orphaned `!$omp do` | **Checked, intended.** It runs inside `ComputeTimeDerivative`'s parallel region (lines 261–313), with the same pattern as legacy. Reply, or add a one-line comment. |
| #142 | 4312761013 | `SurfaceIntegrals.f90:409` | `val` is the function result and is listed `private` | **Checked, true.** `VectorSurfaceIntegral … result(val)` (line 238) uses `val` as scratch in the loop. It works, but a local scratch variable is clearer. Small change. |
| #142 | 4312761095 | `VolumeIntegrals.f90:734` | the directive line may exceed 132 characters | **Checked, wrong:** it is 120. Reply. |
| #143 | 4312743872 | `VolumeMonitor.f90:195` | the help text says `Source`, but the case is `"source"` | **Checked, moot.** The key is lower-cased first (`VolumeMonitor.f90:105`, `call toLower`). Autofix f1f1d100 changed the text to `* source`, which matches legacy's multiphase help. Keep (sync fork #12) or revert. |
| #143 | 4312743968 | `VolumeMonitor.f90:366` | the volume is recomputed at every update | **Checked.** Legacy does the same (`VolumeMonitor.f90:339`). Reply, no change. |

Code Copilot flagged that also exists in a legacy twin:
- #135 → #383: `divV`, plus the TaylorGreenSVVLES references.
- #137 → #384: the `pavg` name and comment only.
- #138 → #385: `need_dealloc`, `SCsensorClass.f90:939`.

#381 has no `Face_Assign` change, since legacy faces have a fixed `storage(2)`.

## CI (19 Oct, 16:40)

Watch with `gh pr checks <n> -R horses-framework/<repo>`.

**Legacy**
- #381: all green.
- #382: one failure, `Run MultiphaseMixedRK` in `build (gfortran, RELEASE, SEQUENTIAL, YES, NO)`.
  - One assert is off: Y-momentum residual 5.93478178e-11 against 5.93478202e-11 (relative 4e-8), in the threaded build.
  - Master a01ca08b4 passed the same job on 15 Oct (run 38722645084). The PR only touches the TE sensor, which multiphase doesn't use.
  - Local legacy runs pass 5/5, both master (`results/lbase-MixedRK`) and all fixes (`lall-MixedRK`), but those were not threaded builds.
  - Likely nondeterminism in threaded multiphase. Rerunning the CI job is cheaper than reproducing it on the laptop.
- #384: `build (ifort, RELEASE, PARALLEL, NO)` fails. Every `mpiexec -n 10` step exits with 143 within about 2 s, which looks like the runner or MPI. Compare with another PR or master before acting.
- #383 and #385: green so far, with some still pending.

**GPU**
- #134, #135, #136, #138 and #142: all green.
- `codecov/patch` fails on #140 (0% of 7 lines), #141 (0% of 6) and #143 (0% of 4); all of it is GPU-only or threaded code. #139 has 26.7%.
- The rest were still pending.

## Waiting on the user

- Fork #14 (`feat/gpu-volume-monitors`, draft `pr-drafts/gpu/10-gpu-volume-monitors.md`): the user works on it first. Its built tree is `gpu-wt/dev-pr2`.
- Team questions in the PRs:
  - #143: the multiphase `ActuatorLineInterpolation` reference values are legacy's (5/10 asserts off by up to 1.4e-7).
  - The `TaylorGreenSVVLES` monitor tolerances are larger than the values they check.
- Housekeeping, ask first: 12 commits with `Claude-Session:` trailers on `claude/eager-lamport-ymhyjk`.

## Tests

**Lock.** Every build, run or `sched.py` queue goes through `gpu-wt/tools/heavy.sh <cmd>`, the machine-wide lock shared with the GMM chat. Run long jobs in the background; the lock waits.

**Trees.** Build in a tree that the GMM chat doesn't own (see the top).
- `base-develop` has fork #9's code with a GPU build (e9bd38a9), which is handy for #140.
- `leg-base` is legacy master a01ca08b4, built; `LEGACY=1` is needed for legacy problem files.
- `leg-all` is an older stack of all the legacy fixes, built.
- `cpu-old` is an old CPU test merge.
- Before a GPU build, run `gpu-wt/tools/prep_dev_tree.sh <abs tree>`. It applies the local cc86 `-gpu` flags and a Cylinder.control edit. Never commit those two files.

**Disk.** About 1.6 GB is free, a GPU tree takes about 2 GB, and `build_gpu.sh` refuses below 1.5 GB. Ask the user before removing any tree.

**GPU suite.**
```
gpu-wt/tools/heavy.sh gpu-wt/tools/suite.sh <tree name under gpu-wt> <label> gpu-wt/tools/cases_dev.txt
gpu-wt/tools/report.py <label> dev
```
`dev-*-r1` is develop's GPU baseline. Use a new label for each run set: `run_case.sh` deletes `results/<tag>` before writing.

**Leak check.**
```
NV_ACC_NOTIFY=16 ./horses3d.ns Cylinder.control 2>&1 | python3 gpu-wt/tools/leaks.py /dev/stdin
```
Expect about 0.01 MB (`gpu-wt/NOTES.md:62`).
