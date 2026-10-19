# Handoff: GMM_develop → develop (fork PR #13), 19 Oct 2026

This chat owns the GMM work. Another chat owns the upstream bug-fix PRs and fork #14 (`HANDOFF-prs.md`), so leave those branches alone. General rules and setup are in `HANDOFF.md`, and the local plan and test log are in `gpu-wt/PLAN.md`. Paths below are relative to `~/Desktop/Horses3d-Epicure`.

## The task (user, 19 Oct)

> look into the ForwardFacingStepSVV CPU failure first. Also simplify the gmm develop changes, maybe consider using code-simplify, this includes comments and everything. Legacy is our objective unless we find it to be wrong, we match legacy by default and only change when there is a reason

What that means here:
- **Legacy is the reference** for behaviour and structure. A difference from legacy needs a reason, such as the GPU or a legacy bug, and the reason goes in the commit message.
- **Make the diff smaller and plainer, comments included.** It adds 574 comment lines against 778 code lines; comments should be as short as the surrounding code's.
- **Keep results bitwise identical** wherever they should not change.

## Branches and trees

| What | Where |
|---|---|
| Fork PR #13 | `feat/gmm-shock-capturing` (99c639c5). It is upstream develop `1c077fea` plus 13 commits (9a07c89a..99c639c5), all by Rodrigoansf. It does **not** contain the NodalStorage fix (e9bd38a9, in #140). |
| Work branch | `simplify/gmm-shock-capturing`, still at 99c639c5, not pushed. Checked out in `gpu-wt/gmm`. Its untracked files are `.built-*` markers, `IBM_Cylinder/IBM/Mask_cylinder_0000000000.tec`, `Solver/test/NavierStokes/TaylorGreenAniso/` (a scratch case) and `build-gpu.log`. Never `git add -A`. |
| AV prolongation on the device | `feat/gmm-avisc-device` (f345969a): 2 commits on #13, pushed to the fork, no PR. Rebase it once #13 changes. Draft: `pr-drafts/gpu/11-gmm-avisc-device.md`. |
| AV work on the end goal | `topic/avprolong-end` (90eb32f3) in `gpu-wt/dev-pr`, with a GPU build |
| End goal (test branch) | `goal/end-goal` (c86da56f) in `gpu-wt/gwork`. It is develop plus every feature branch merged **before the 19 Oct restyle**: same code, old SHAs. |
| CPU build of the end goal | `gpu-wt/cpu-new`, detached at c86da56f. **Its binary has debug code: rebuild it before use.** |
| Legacy reference | `gpu-wt/leg-base` = upstream master a01ca08b4, built. You can also read files with `git -C horses3d show upstream/master:<path>`. The `horses3d` checkout itself is the fork's old `master` (2214d654a), which differs in `EllipticBR1.f90` and `horses2tecplot/Storage.f90`; don't read legacy from there. |
| horses-framework `GMM_develop` | still at 8bb13275. The fork's `GMM_develop` is `gmm/final2` (8b9d8f21: adds the NodalStorage fix). Pushing it upstream is the user's job. |

The upstream push is a fast-forward:
```
git -C horses3d-gpu push git@github.com:horses-framework/horses3d-gpu.git gmm/final2:refs/heads/GMM_develop
```

PR texts:
- #13's text is `pr-drafts/gpu/9-gmm-shock-capturing.md`. It is also stored in `gpu-wt/tools/restyle_prs.py` (line 81; line 100 for the AV branch).
- If you change it, change both places. Otherwise a `restyle_prs.py` run in the PR chat reverts it.
- `restyle_messages.py` is keyed by the old SHAs and has already been applied.

## 1. ForwardFacingStepSVV on the CPU: cause found, not fixed

**Symptom.** CPU builds of the GMM code fail `ForwardFacingStepSVV` 3/6:
- `results/cpuend-*` (end goal, sequential), `cpuavp-*` (AV branch) and `ffsv-cpu-base` all fail;
- legacy (`ffsv-leg-base`) passes 6/6;
- on the GPU it passes 6/6 on the end goal (`gend3-*`) and on `gmm/final2` (`gfin2-*`), agreeing with legacy to about 1e-12.

On the CPU the sensor equals legacy's, but the residuals differ from iteration 2. The CPU SVV dissipation is 0; legacy and the GPU give 2.36e-5.

On #13 alone, FFS crashes on the GPU (`gfeat-ForwardFacingStepSVV-r1`, illegal address), because #13 lacks the NodalStorage fix. No CPU FFS run of #13 itself exists yet.

**What is known:**
- `SC_FlattenMethod` (`ShockCapturing.f90:357`) flattens the method with `select type`. It is called twice from `SC_SyncDeviceConfig` (`:343`, `:344`).
- In the CPU build `SCdev_isSVV(1)` stays false, so the SVV region takes the non-SVV flux path: the unfiltered physical flux times `mu1 * hn`, 250–1000× too large.
- gfortran 12.4 at -O3 inlines `SC_FlattenMethod` there. A gdb watchpoint showed `SCdev_isSVV` is never written.
- Any debug print changes the inlining and hides the bug. The standalone copy compares the vtab addresses correctly. nvfortran compiles it correctly.
- The details don't fully add up:
  - `class default` sets `SCdev_onDevice = .false.` (`:406`), which would send everything through the host `SC_viscosity`.
  - What was seen instead is the device path, with `isSVV` false and `mu1` set. So the SVV method seems to go through the `SC_NoSVV_t` stores, or the stores of the two inlined calls get mixed.
  - Watch `SCdev_onDevice` and `SCdev_mu1(1)` too.
- Only FFS is known to be wrong. `TaylorGreenSVVLES` (SVV only) and `CylinderGMM` (non-filtered twice) match the GPU or legacy on the CPU (`cpuend-*`).

**FFS variants.** `gpu-wt/tools/ffs_variants_cpu.sh` writes to `results/ffsv-*`. Its CPU side is `cpu-new` (end goal c86da56f, threaded build, run with 1 thread). To rerun on #13, change `cpu-new` to `gmm` in its tree loop; legacy runs need `LEGACY=1 run_case.sh leg-base …`.

First iteration where the CPU differs from legacy by more than 1e-9:

| Variant | First differing iteration |
|---|---|
| base (SVV first, non-filtered second) | 2 |
| non-filtered first | 2 |
| SVV only (no second method) | 3 |
| no shock capturing | none |

**Not proven yet:** that this is a compiler bug and not undefined behaviour in our code. A gfortran-13 build settles it cheaply.
- `Makefile.in` keys its FFLAGS on `FC == gfortran`, so `make FC=gfortran-13` builds with no flags. Use a PATH shim instead:
  ```
  mkdir -p <scratch>/gf13 && ln -sf /usr/bin/gfortran-13 <scratch>/gf13/gfortran
  PATH=<scratch>/gf13:$PATH gpu-wt/tools/heavy.sh gpu-wt/tools/build_cpu_full.sh $PWD/gpu-wt/gmm
  ```
- Run the case with the same PATH, so its SETUP is built with the same compiler.

**Planned fix:** drop the `select type`. For example, each method writes its own flat configuration in its `Initialize` (`SVV_initialize`, the non-filtered one), with a flag for methods that cannot be flattened. Pick whatever is closest to legacy's structure.

## 2. Region choice: match legacy

This was a pending user decision (`sc-switch` in PLAN.md). It is now settled by "legacy is our objective".

Legacy `SC_viscosity` (`gpu-wt/leg-base/Solver/src/libs/discretization/ShockCapturing.f90:267`):
- where the sensor is `>= 1`, it applies method 2 if there is one, and nothing otherwise;
- where `0 < sensor < 1`, it applies method 1.

On #13:
- the host `SC_viscosity` (`:475`) is the same as legacy;
- the device `SC_ComputeElementAviscFlux` (`:558`; region choice `:594-600`, SVV override `:606`) applies method 1 where `sensor >= 1` and there is no method 2, unless method 1 is SVV.

Make the device routine match legacy. No CI case has a non-SVV first method without a second method, so no CI result should change.

## 3. Simplify (the `/simplify` skill)

Phase 0 is done: `gpu-wt/design/simplify/gmm.diff` = `git diff 1c077fea 99c639c5`, 2404 lines, 18 files, +1613/−79.

Most of it is in:

| File | Lines |
|---|---|
| `ShockCapturing.f90` | +744/−1 |
| `SVV.f90` | +199/−14 |
| `SpatialDiscretization.f90` | +173/−28 |
| `VariableConversion_NS.f90` | +96/−4 |
| `HexMesh.f90` | +75/−6 |

No fixes have been applied yet; two earlier review agents died at the usage limit. Run the review with at most two agents at a time, or inline.

Things already seen:
- The `select type` (§1) and the region choice (§2).
- The comment volume, and some comments that are wrong:
  - The GMM centroid comment in `Clustering.f90` (9b567ce8, and its commit message) says gfortran reseeds `random_number` from the OS on every run. But legacy master `lbase-CylinderGMM` r1–r3 are bitwise identical, so give the real reason (CPU and GPU agree, whatever the compiler).
  - The `SCDEV_DISPATCH` header names `SC_ElementViscosity`, which does not exist.
- `Solver/test/NavierStokes/Cylinder/bench.control` (+66) looks like a leftover benchmark. It is the only file in 21816c5d "Gradient Variables initial commit", so dropping it drops that commit. Ask the user first.
- Keep each commit's subject, and rewrite or squash only where it helps the reader. Messages are short; see the style rule in `HANDOFF.md`.

## 4. Tests

Run one heavy job at a time. Every build, run or `sched.py` queue goes through `gpu-wt/tools/heavy.sh <cmd>`, a machine-wide lock shared with the PR chat. Run long jobs in the background, since the lock waits.

**General**
- `run_case.sh` takes the tree name relative to `gpu-wt` (`gmm`), and the build scripts take an absolute path.
- A CPU build and a GPU build in the same tree each `make allclean` the other.
- Use a new label for every run set (e.g. `cpusimp`, `gsimp`), and check that `ls gpu-wt/results | grep '^<label>-'` is empty first. `run_case.sh` deletes `results/<tag>` before writing, so reusing `gfeat`, `cpugfeat`, `gmm`, `lbase` or `ffsv` destroys a baseline.
- Disk is tight: about 1.6 GB free on 19 Oct, and `build_gpu.sh` refuses below 1.5 GB. Rebuild in `gmm` rather than making a new tree. Ask the user before removing any worktree.

**CPU first**
1. Build:
   ```
   gpu-wt/tools/heavy.sh gpu-wt/tools/build_cpu_full.sh $PWD/gpu-wt/gmm
   ```
   `build_cpu.sh` skips the add-ons that `ci_local.py` needs.
2. FFS must match legacy: compare with `results/ffsv-leg-base` using `gpu-wt/tools/compare.py <dirA> <dirB>`.
3. CPU suite:
   - Run the cases in `tools/cases_cpu.txt`, tagged `<label>-<casedir>-<control stem>`, so that `tools/report.py <label> cpugfeat` finds the baseline.
   - It must be bitwise where nothing should change.
   - The shock-capturing cases have no #13 CPU baseline: compare them with `lbase-*` (legacy).
4. CI add-ons:
   ```
   python3 gpu-wt/tools/ci_local.py <abs tree> .github/workflows/CI_horses2plt.yml <outdir>
   ```
   - Do the same with `CI_mergeStatistics.yml`. The baselines are `ci-h2p-cpugfeat.txt` (12/12) and `ci-merge-cpugfeat.txt` (7/7).
   - Afterwards: `git -C <tree> checkout -- Solver/test/AddOns && git -C <tree> clean -fdq Solver/test/AddOns`.
5. Templates: `make_plan3.py` section D (CPU suite and `ci_local`) and `make_plan8.py` (CPU shock capturing, threaded). **Don't use their `prep()` on `gmm`**: it runs `git checkout -- Solver` and detaches HEAD.
6. Threaded:
   - Build with `build_cpu_full.sh <tree> YES`, then run with `OMP_NUM_THREADS=1` and `4` (see `tools/end_omp.sh`).
   - #13 alone lacks the `!$omp do` around the element loop in `TimeDerivative_ComputeArtificialViscosity` (gmm `SpatialDiscretization.f90:1321-1327`). That is the first hunk of f345969a, which is only on `feat/gmm-avisc-device`.
   - So on #13, expect FFS and TaylorGreenSVVLES to differ between 1 and 4 threads. Ask the user whether that hunk should move into #13.

**GPU**
1. Prepare and build:
   ```
   gpu-wt/tools/prep_dev_tree.sh $PWD/gpu-wt/gmm
   gpu-wt/tools/heavy.sh gpu-wt/tools/build_gpu.sh $PWD/gpu-wt/gmm
   ```
   `prep_dev_tree.sh` applies the cc86 `-gpu` flags and a `Reference surface` line in `Cylinder.control`. Without that line `Cylinder` crashes on #13, which lacks the ParamfileRegions fix. **Never commit those two files.** Stage by name, and restore them with `git -C gpu-wt/gmm checkout -- Solver/Makefile.in Solver/test/NavierStokes/Cylinder/Cylinder.control` before committing.
2. Run the suite and compare:
   ```
   gpu-wt/tools/heavy.sh gpu-wt/tools/suite.sh gmm <label> gpu-wt/tools/cases_gmm.txt
   gpu-wt/tools/report.py <label> gfeat
   ```
3. FFS will crash on the GPU in `gmm`, and its `gfeat` baseline is a crash too. For GPU FFS evidence, merge `feat/gpu-device-data` into a throwaway branch (never into the PR branch), or test on `gwork`.
4. Many runs: use `tools/sched.py` with a plan file. `make_plan8.py` and `make_plan9.py` are examples; mind their `prep()`.

## 5. After the tests

1. Show the user the diff and the results before rewriting or pushing #13.
2. Then:
   - push to the fork (allowed);
   - update #13's body with `gh api -X PATCH repos/Rodrigoansf/horses3d-gpu/pulls/13`, keeping draft 9 and `restyle_prs.py` in step;
   - rebase `feat/gmm-avisc-device`.
3. If the user wants it, rebuild `goal/end-goal` from the new branches.
4. Later, and only if the user asks:
   - pnc-faces: the design is done, the critic was not run (`gpu-wt/design/pnc-faces`);
   - small items: `TruncationErrorClass` `private(S)`, and the nvfortran scalar-deallocate audit.
