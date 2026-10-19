# Starting prompts for the two chats (19 Oct 2026)

Open each chat in `~/Desktop/Horses3d-Epicure`.

## PRs chat

```
You're picking up the upstream bug-fix PRs for horses3d and horses3d-gpu. Read horses3d-gpu/review/HANDOFF.md (the rules and the "Two chats" section), then horses3d-gpu/review/HANDOFF-prs.md.

Note: on 19 Oct I applied Copilot Autofix commits in the GitHub UI on #137, #139, #140, #141 and #143, so those upstream branches are one commit ahead of their fork branches. Fetch upstream and review the upstream heads, and tell me whether you'd keep each autofix commit.

First task: the 18 Copilot review comments on horses-framework/horses3d-gpu #134-#143. Check each one against the code and against legacy, then show me a table with the comment, your verdict, and the proposed action (a code change, or the reply text). Also give me the CI state of all 15 PRs, and check whether legacy master fails MultiphaseMixedRK the way #382 does.

Don't push to horses-framework or post anything on GitHub until I say so. Builds and runs go through gpu-wt/tools/heavy.sh, one at a time.
```

## GMM chat

```
You're picking up the GMM_develop -> develop work (fork PR #13). Read horses3d-gpu/review/HANDOFF.md (the rules and the "Two chats" section), then horses3d-gpu/review/HANDOFF-gmm.md and gpu-wt/PLAN.md.

First, the ForwardFacingStepSVV CPU failure. Confirm the gfortran select-type miscompile cheaply with a gfortran-13 build (HANDOFF-gmm §1 says how), then fix it without the select type, and make the device region choice match legacy.

Then simplify the GMM changes, comments included. Use /simplify with at most 2 agents at a time. Legacy is our objective unless we find it to be wrong: we match legacy by default and only change when there is a reason.

Work in gpu-wt/gmm on simplify/gmm-shock-capturing. Run one heavy job at a time through gpu-wt/tools/heavy.sh. Show me the diff and the test results before you rewrite or push #13.
```
