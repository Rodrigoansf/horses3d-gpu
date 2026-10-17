# Handoff: stack-PR review (#113–#117), continued locally

Read this first, then `review/STATUS.md` (section 0) and `review/pr-drafts/`.

## Who and what

The user is Rodrigoansf, a maintainer of horses-framework/horses3d-gpu, a high-order DG CFD solver ported to GPU with OpenACC/nvfortran. Its priorities are compressible Navier–Stokes and multiphase; NSSA, iNS and CAA are not. Legacy is horses-framework/horses3d, a separate repo; some bugs exist in both.

The job: review the zalbanob stack PRs (horses-framework/horses3d-gpu#113 to #117) and turn the useful parts into small, isolated, discussable PRs. Duplicates of Miguel's gradvars work, of the user's GMM_develop shock-capturing work, or of develop are dropped, and so are regressions.

## Rules (from the user)

- **Never push to horses-framework**, except `GMM_develop` (the user's research branch) after testing. Work only in the forks, Rodrigoansf/horses3d-gpu and Rodrigoansf/horses3d, and open no PRs in horses-framework until the user says so.
- **Run PRs by the user before making them.** Keep each PR small and readable: one branch for minor fixes (fixes that don't change results), and one branch per change that does change results.
- **Check with the user before going out of scope.** Don't start a new line of work, or fix something you just noticed, without asking: it may be someone else's work. Note it and ask.
- **Commits are the user's:** author `Rodrigoansf <rodrigoansf@gmail.com>`, with no `Co-Authored-By: Claude` line. PR bodies carry no "Generated with Claude Code" footer.
- Write PR descriptions slowly and plainly, explaining the code for researchers who haven't seen it.
- Avoid performance regressions, especially extra host↔device transfers.
- Multi-GPU tests are run by hand on the cluster.
- Branch roles: `main` is heavily guarded, `develop` holds tested features, and other branches are work in progress.

## Setup in an empty folder

```
git clone https://github.com/Rodrigoansf/horses3d-gpu
git clone https://github.com/Rodrigoansf/horses3d
git -C horses3d-gpu remote add upstream https://github.com/horses-framework/horses3d-gpu
git -C horses3d     remote add upstream https://github.com/horses-framework/horses3d
git -C horses3d-gpu fetch --all && git -C horses3d fetch --all
git -C horses3d-gpu checkout claude/eager-lamport-ymhyjk   # review docs live here
```

Pushing uses SSH (`git@github.com:Rodrigoansf/...`) with the user's `~/.ssh/Rod` key, set per clone with `git config core.sshCommand "ssh -i ~/.ssh/Rod -o IdentitiesOnly=yes"`. The `upstream` push URL is set to `DISABLED-never-push-to-horses-framework` on purpose.

## Where things stand (17 Oct 2026)

Done: the commit-attribution rewrite (15 Oct), the team decision on targets, all branches rebased and tested on the laptop GPU. **Read `review/STATUS.md` section 0 for the branch table.** In short:

- horses3d-gpu fork PRs to `develop`: #1 minor fixes, #3 split-form, #4 SVV divV, #5 TE source term, #6 limiter, #7 aliasing realloc, #8 ParamfileRegions. #4 and #5 now target `develop`; #2 (`fix/minor-GMM`) is closed. `gh` is installed and logged in (2.45: `gh pr edit` fails on GitHub's retired classic Projects API, use `gh api -X PATCH repos/<repo>/pulls/<n>` instead).
- horses-framework `GMM_develop` was pushed directly (approved by the user; fast-forward): the GMM fixes, the **SVV GPU port**, a merge of `develop`, and the develop fixes the user asked for. Record: `review/pr-drafts/gpu/2-GMM_develop-direct.md`.
- Legacy fork PRs #1–#5 to `master`, rebased on `a01ca08b4`.
- PR descriptions: `review/pr-drafts/`, already copied into every fork PR (17 Oct).

The user's rule now: **no PRs in horses-framework until they have reviewed everything with all tests done.** Pushing to `GMM_develop` (their research branch) is allowed after testing.

## Open items (ask the user before starting any of them)

- Upstream PRs in horses-framework, once the user has reviewed the fork PRs.
- Multi-GPU / MPI runs on the cluster (`CI_parallel_GPU.yml`), for the develop PRs and `GMM_develop`.
- Delete the superseded branches; they still carry commits authored or committed by Claude (`fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`, `legacy/sc-sensor-omp-shared`, `legacy/te-sensor-padapt-mpi`). This review branch also has `Claude-Session:` trailers in 12 commits; ask before rewriting it. Branches to delete (`stack-pick/*`, `fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`, `review/gpu-results` in the GPU fork; `legacy/te-sensor-padapt-mpi`, `legacy/sc-sensor-omp-shared` in the legacy fork). Do **not** touch `miguel_*`, `arr/*` and `feature/*`.
- Known, not being fixed here: see STATUS.md section 0 (new findings) and the list below.
  - Anisotropic orders crash on GPU in `HexMesh_ProlongSolToFaces`.
  - `Face_AdaptSolToFace` lost legacy's p-nonconforming interpolation.
  - GPU volume monitors are stale (kinetic-energy rate reads 0 on the GPU).
  - `TruncationErrorClass` has `private(S)` with `S` zeroed outside the OpenMP loop.
  - TaylorGreenSVVLES's volume-monitor asserts have tolerances larger than the values they check (the SVV-dissipation reference is 7.8e-8; CPU and GPU both give 2.6e-8).
  - `ForwardFacingStepSVV` crashes on the GPU on `GMM_develop`.
  - Artificial-viscosity face prolongation on `GMM_develop` is still a host round trip (`SC_ProlongAviscFluxToFaces`).

## Laptop limits (important)

15 GiB RAM: parallel builds and test runs OOM-killed the Claude app three times. Run heavy jobs one at a time, or with `gpu-wt/tools/sched.py` (memory-aware, one GPU run at a time, each job capped with `systemd-run --user --scope -p MemoryMax=...`). The GPU throttles to ~210 MHz above ~90 °C, so only interleaved timings are comparable. Local test workspace: `~/Desktop/Horses3d-Epicure/gpu-wt` (`NOTES.md`, `tools/`, `results/`).

## Build and test notes

- **Builds:** run `cd Solver && ./configure && make ns mu COMPILER=gfortran MODE=RELEASE COMM=SEQUENTIAL ENABLE_THREADS=NO`. Don't use `-j`: the Makefile isn't parallel-safe (module order).
- **GPU builds:** use `COMPILER=nvfortran COMM=SERIAL` with a local cc86 edit to the `-gpu=` flags in `Makefile.in`; don't commit that edit. nvfortran forces `ENABLE_THREADS=NO`. A full disk during the device link can produce a truncated binary while `make` still reports success; check free space or set `TMPDIR`.
- **Test problem files:** build them with `make ns` (or `make mu`) in each test's `SETUP`, not plain `make`, which also tries the NSSA/iNS libraries.
- **`./configure`** rewrites two `Solver/test/Acoustic/*/horses3d.caa` symlinks in the legacy repo. Never commit them; restore with `git checkout -- Solver/test/Acoustic`.
- **MPI** without METIS needs `partitioning = SFC`.
- **Scratch cases** used as PR evidence are in `review/scratch-cases/`.
