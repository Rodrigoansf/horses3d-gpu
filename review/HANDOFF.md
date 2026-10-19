# Handoff: stack-PR review (#113–#117), continued locally

Read this first, then `review/STATUS.md` (section 0) and `review/pr-drafts/`.

## Two chats (since 19 Oct)

The work is split between two Claude chats on the same laptop.

| Chat | Handoff | Owns |
|---|---|---|
| PRs | `review/HANDOFF-prs.md` | upstream horses3d-gpu #134–#143 and horses3d #381–#385, their fork twins, fork #14, worktree `gpu-wt/prs-edit` |
| GMM | `review/HANDOFF-gmm.md` | fork #13 (`feat/gmm-shock-capturing`), `feat/gmm-avisc-device`, `GMM_develop`, `goal/end-goal`, worktrees `gpu-wt/gmm`, `gwork`, `dev-pr` and `cpu-new` |

Both chats share the machine and the git repos:
- **One heavy job at a time, machine-wide.** Every build, solver run or `sched.py` queue goes through `gpu-wt/tools/heavy.sh <cmd>`, a `flock` on `gpu-wt/.heavy.lock`; the holder is in `.heavy.lock.holder`. Run long jobs in the background, since the lock waits.
- **Usage limit:** at most 2–3 agents per chat, run in sequence. Wide workflows have hit the limit and killed the session several times.
- **Git:**
  - Don't touch the other chat's branches or worktrees.
  - Never use a bare `git stash`: the stash is shared by all worktrees.
  - Don't commit to `claude/eager-lamport-ymhyjk` from both chats at once; fetch or rebase before pushing.
- **Log:** each chat appends to `gpu-wt/PLAN.md`'s progress log, with its entries prefixed `[prs]` or `[gmm]`.

## Who and what

The user is Rodrigoansf, a maintainer of horses-framework/horses3d-gpu, a high-order DG CFD solver ported to GPU with OpenACC/nvfortran. Its priorities are compressible Navier–Stokes and multiphase; NSSA, iNS and CAA are not. Legacy is horses-framework/horses3d, a separate repo; some bugs exist in both.

The job: review the zalbanob stack PRs (horses-framework/horses3d-gpu#113 to #117) and turn the useful parts into small, isolated, discussable PRs. Duplicates of Miguel's gradvars work, of the user's GMM_develop shock-capturing work, or of develop are dropped, and so are regressions.

## Rules (from the user)

- **Never push to horses-framework without the user's go for that push.** Work in the forks, Rodrigoansf/horses3d-gpu and Rodrigoansf/horses3d. Since 19 Oct the bug-fix PRs are open upstream (`bug-fix-*` branches, see `HANDOFF-prs.md`); each push to them, and each comment posted there, needs a yes first.
- **Run PRs by the user before making them.** Keep each PR small and readable: one branch for minor fixes (fixes that don't change results), and one branch per change that does change results.
- **Check with the user before going out of scope.** Don't start a new line of work, or fix something you just noticed, without asking: it may be someone else's work. Note it and ask.
- **Commits are the user's:** author `Rodrigoansf <rodrigoansf@gmail.com>`, with no `Co-Authored-By` line for Claude or Copilot (commits made in GitHub's UI break this rule). PR bodies carry no "Generated with Claude Code" footer.
- PR descriptions and commit messages are short and plain, in amrueda's style. A commit is a subject plus 1–2 sentences. A PR is 1–3 sentences, a few bullets and one test line.
- Legacy is the reference: match legacy behaviour by default, and change it only with a reason, stated in the commit.
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

## Where things stand (18 Oct 2026)

Newest (19 Oct): the bug-fix PRs are open upstream and the work is split into two chats (above). Before that: fork PR #1 is split into #9–#12, `GMM_develop` → `develop` is #13, and `goal/end-goal` merges everything (see `STATUS.md` §0). The local plan, design loop and test log are in `gpu-wt/PLAN.md` on the laptop.

### 17 Oct

Done: the commit-attribution rewrite (15 Oct), the team decision on targets, all branches rebased and tested on the laptop GPU. **Read `review/STATUS.md` section 0 for the branch table.** In short:

- horses3d-gpu fork PRs to `develop`: #1 minor fixes, #3 split-form, #4 SVV divV, #5 TE source term, #6 limiter, #7 aliasing realloc, #8 ParamfileRegions. #4 and #5 now target `develop`; #2 (`fix/minor-GMM`) is closed. `gh` is installed and logged in (2.45: `gh pr edit` fails on GitHub's retired classic Projects API, use `gh api -X PATCH repos/<repo>/pulls/<n>` instead).
- horses-framework `GMM_develop` was pushed directly (approved by the user; fast-forward): the GMM fixes, the **SVV GPU port**, a merge of `develop`, and the develop fixes the user asked for. Record: `review/pr-drafts/gpu/2-GMM_develop-direct.md`.
- Legacy fork PRs #1–#5 target `upstream-master` (the fork's copy of upstream master, `a01ca08b4`). The fork's own `master` is the user's MMS branch (#349): don't use it as a base.
- PR descriptions: `review/pr-drafts/`, already copied into every fork PR (17 Oct).

Since 19 Oct the bug-fix PRs are open upstream (see `HANDOFF-prs.md`). The other fork PRs (#13, #14 and the AV branch) still wait for the user's go. Pushing to `GMM_develop` (their research branch) is allowed after testing.

## Open items (ask the user before starting any of them)

- Multi-GPU / MPI runs on the cluster (`CI_parallel_GPU.yml`), for the develop PRs and `GMM_develop`.
- Delete the superseded branches; they still carry commits authored or committed by Claude (`fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`, `legacy/sc-sensor-omp-shared`, `legacy/te-sensor-padapt-mpi`). This review branch also has `Claude-Session:` trailers in 12 commits; ask before rewriting it. Branches to delete (`stack-pick/*`, `fix/gpu-port-develop`, `fix/gpu-port-GMM`, `discuss/legacy-shared-bugs`, `review/gpu-results` in the GPU fork; `legacy/te-sensor-padapt-mpi`, `legacy/sc-sensor-omp-shared` in the legacy fork). Do **not** touch `miguel_*`, `arr/*` and `feature/*`.
- Known, not being fixed here: see STATUS.md section 0 (new findings) and the list below.
  - ~~Anisotropic orders crash on GPU~~: fixed in fork PR #9 (NodalStorage copied to the device in full).
  - `Face_AdaptSolToFace` lost legacy's p-nonconforming interpolation.
  - GPU volume monitors are stale (kinetic-energy rate reads 0 on the GPU).
  - `TruncationErrorClass` has `private(S)` with `S` zeroed outside the OpenMP loop.
  - TaylorGreenSVVLES's volume-monitor asserts have tolerances larger than the values they check (the SVV-dissipation reference is 7.8e-8; CPU and GPU both give 2.6e-8).
  - ~~`ForwardFacingStepSVV` crashes on the GPU on `GMM_develop`~~: same bug (2D mesh = order 0 in one direction), fixed in #9.
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
