[![ci](https://github.com/VonBorstel-J/tide/actions/workflows/ci.yml/badge.svg)](https://github.com/VonBorstel-J/tide/actions/workflows/ci.yml)

# Tide

I run coding jobs on a Windows PC and review them from my phone. Tide gives each change its own branch, runs the tests, and lets me see which jobs need a decision. A worker can hang, hit its memory limit, or stop halfway through a change. The supervisor keeps enough state on disk to pick up the queue after a restart.

## Watch a job recover

On Windows with PowerShell 7, run this from the repository root.

```powershell
pwsh -File kitchen/demo.ps1 -Open
```

The demo starts ten simulated workers in a temporary folder. Watch the one that fails on its first try and the one that keeps failing. Halfway through, the demo restarts the supervisor. The deployment step waits for approval, which the demo supplies. At the end you can inspect the status page and the event log. [Demo script](kitchen/demo.ps1) · [Supervisor tests](tests/Test-KitchenSupervisor.ps1)

In daily use I make that decision from the Board, the phone interface. I can read what a job wants to change, approve it, or stop it. The Board reaches the PC over Tailscale. The Yard is the job runner on the PC. [Phone interface](pass-app/README.md) · [Job runner](kitchen/README.md)

## Running Tide

The Windows setup uses one account. Paths default to `%USERPROFILE%` and private settings live under `%LOCALAPPDATA%\brain-kitchen`. The public repository starts with the October 24, 2026 snapshot. [Build and contribution notes](kitchen/BUILDING.md) · [License](LICENSE) · [Bundled font license](pass-app/public/OFL.txt) · [Report a security issue](SECURITY.md)

The following reference covers the scripts that maintain notes between jobs.

**Run a test suite.** `pwsh -NoProfile -File scripts/run-bounded.ps1 -Script tests/Test-PassApp.ps1 -TimeoutSeconds 1200` (every suite in `tests/` runs the same way).

## The brain checks

Keeps the agents' notes folder (`%USERPROFILE%\gemini-brain`) healthy. No network access; no real secrets in this repo.

## Two kinds of memory
- **Long-term memory** = the brain repo (`AGENT_CONTEXT.md`, `memory/`, project status). Slow-changing facts. Risks: stale facts, bloat, broken pointers, leaked secrets.
- **Short-term memory** = `memory/NOW.md` in the brain. The current directive, active threads, open loops and what we are waiting on. Changes daily. Risk: it goes stale and agents act on yesterday's picture.

## v0 (built, tested): deterministic, no model, no background process
```powershell
pwsh -File scripts/memory-check.ps1      # health report; exit 1 if any FAIL
pwsh -File scripts/checkpoint.ps1        # timestamped copy of NOW.md into data\checkpoints (keeps the newest 30)
pwsh -NoProfile -File tests/Test-BrainMonitor.ps1
```
Checks: context file within its one-page budget; NOW.md exists, is stamped, fresh, short, and has its sections; every `memory/...` or `projects/...` pointer in the two always-loaded files resolves (pointers with `..` or other unsafe parts are skipped and counted); no secret-looking content or secret-type files (file:line and pattern name only, never the value); protected paths are git-ignored; the brain has no git remote and no uncommitted tracked changes; no memory file untouched for 60+ days; links in the brain are reported (WARN) and never followed.

## Control-plane scripts (built, tested, not wired into any settings)
Run every test through `scripts\run-bounded.ps1 -Script tests\Test-X.ps1 -TimeoutSeconds 300 -MaxMB 1500`.

| Script | Use | Exit codes |
|---|---|---|
| `scripts\handoff.ps1 [-BrainPath] [-Repos a;b] [-OutPath]` | Builds the toolbox talk (code: `memory\BOOT.md`) (<= 10000 chars): the shift handover note (code: `memory\PICKUP.md`, first 30 lines), the Creed (never cut; over the cap other sections shrink first, NOW before repos), World & self (ZG-08: the lobe's frame from the cloud-safe `csf-brief.json` only, never `csf.json`; home `ZEITGEISTD_HOME`, else `<kitchen>\lobe`; missing, stale or refused = one plain line), NOW head, repo status + last 5 commits, pending approvals, active work orders (code: jobs), the Yard line (code: `kitchen`). Never touches HANDOFF.md; refuses on secret match and then also deletes any stale BOOT.md at OutPath. Commit subjects, registry names and NOW lines are untrusted data (control/bidi/zero-width chars stripped, lines capped) | 0 ok, 2 refused |
| `scripts\approvals.ps1 add\|list\|answer\|verify` | Approvals queue `memory\inbox\approvals.md`. `add -Level LOW\|MED\|HIGH -Text`, `answer -Reply 'A3 yes, A4 no'`, `verify -Id A3 -Text '<exact action>'` (yes + sha match only). Unanswered = denied; `yes all` never approves HIGH. **FROZEN** (ORG.md): no new features. Advisory only: the sha is unkeyed and any agent can edit the file | 0 ok, 1 verify denied, 2 error |
| `scripts\run-registry.ps1 register\|list\|reap\|depth` | Run registry (`%LOCALAPPDATA%\brain-runs\runs.jsonl`, env `BRAIN_RUNS`). `register -Name -ProcessId -EndCondition [-MaxMinutes]`; `reap` reports only, `-Kill` stops overdue registered pids whose start time matches; `depth -Check`. **FROZEN** (ORG.md): no new features. The depth cap only works if the launching agent sets BRAIN_AGENT_DEPTH; nothing sets it today, so depth reads 0 and the cap never blocks | 0 ok, 2 refused, 3 depth >= 2 |
| `scripts\budget-check.ps1 [-BrainPath]` | Size budgets: AGENT_CONTEXT 40 lines, NOW 40, HANDOFF 120, BOOT 10000 chars, ORG 80. **FROZEN** (ORG.md): no new features | 0 ok, 1 WARN, 2 bad path |
| `scripts\privacy-map-check.ps1 [-MapPath] [-RepoRoot] [-Quiet]` | Checks the data map (gemini-brain `projects\tide\privacy-map.md`) against the code: every crew (code: cook) in `kitchen\kitchen.json` appears as `cook:<name>`, every Spec (code: `recipe`) with a Private step or career-folder/resume use as `recipe:<name>`, every cited `file:line` still exists, every row cites code or says unknown. Read-only. Tests: `tests\Test-Privacy.ps1` (also proves push carries only fixed words and a private work order never gets a Cloud crew) | 0 ok, 1 mismatch, 2 map or kitchen.json missing |
| `scripts\secret-patterns.ps1` | Shared secret patterns (dot-sourced by memory-check, handoff, approvals); token shapes mirror the brain and demo pre-commit hooks, tests in `tests\Test-SecretPatterns.ps1` | n/a |
| `scripts\usage-report.ps1 [-ProjectsDir] [-Since yyyy-MM-dd] [-OutPath f.md] [-Json] [-Window N] [-WInput/-WCacheWrite/-WCacheRead/-WOutput]` | Deterministic token-efficiency report over Claude Code transcripts (main + subagent), streaming, read-only. Per session/total: turns, fresh input, cache write/read, output, weighted units (APPROXIMATE relative weights 1/1.25/0.1/5, NOT dollars); boot cost (context of first main-thread turn; min/median/max); top subagents; main-context peak and share of units above 50%/65% of the window; cache-read share; per model; per day (UTC). Reads only numeric usage fields, timestamp, model, message/agent ids, isSidechain and agentType; never message text. Test: `tests\Test-UsageReport.ps1` (synthetic fixtures). Baseline: `docs\USAGE_BASELINE_2026-10-10.md` | 0 ok, 2 bad argument |
| `scripts\weekly-line.ps1 [-PlanPath] [-Scoreboard] [-Days 7] [-Force]` | Weekly performance line for the Watch to call (no scheduled task): reads `kitchen\scoreboard.ps1 -Json` (read-only, under run-bounded) and appends one dated line (work order to merge, a MEAN, as the scoreboard reports it; tokens per merge; first try %) under `## Weekly line` in the tide performance plan. Writes only when the newest line is 7+ days old (-Force anyway). Test: `tests\Test-WeeklyLine.ps1` (fake scoreboard) | 0 written or not due, 1 scoreboard gave no numbers, 2 plan missing |

## v1 (planned): a local model proposes, scripts write
A local model (Ollama; the 7B that fits the 8 GB GPU) reads recent session notes and commits and writes **proposals** into `data/inbox/` (suggested NOW.md update, stale-fact candidates, contradictions with quoted evidence). It never writes to the brain. A deterministic script applies a proposal only after Jordan (or a reviewing agent) approves, then commits. Untrusted text (web pages, tool output) is treated as data: instructions inside it are flagged, not followed. Needs its own spec, tests and a security review before it is built.

## v2 (planned, needs explicit approval): runs in the background
A scheduled task on the rig runs the check and checkpoint on an interval and surfaces failures. Installing a scheduled task is a system change, so it waits for a clear yes.

## Safety design
- Read-only on the brain: tests prove the brain is byte-identical after a run.
- Protected paths (`memory/evie`, `memory/user/finances`, `projects/life_admin`, `projects/evie_admin`, `memory/user/USER_IDENTITY.md`, `projects/naf`) are skipped and never opened; they appear only as a count. Tests plant secrets there and assert nothing leaks.
- Never follows links: every file or folder link (junction or symlink) inside the brain is skipped, counted and named in a `[WARN] link` line (first 5 paths); nothing behind it is read, and `checkpoint.ps1` refuses to copy when `memory\` or `NOW.md` is a link. Only files the walk saw as plain files are ever read. Pointers containing `.`/`..`, a backslash or a colon are counted, never echoed or probed, and pointer existence is decided from the walk's file list, not the disk. Skips `node_modules`, `.git` and similar.
- Output lives only in this repo's `data/` (git-ignored).

## Limits (honest)
- Pattern-based: it finds secret-shaped text and size or age problems. It cannot judge whether a fact is *true* or two notes contradict in meaning; that is what v1's model is for, and the model can be wrong, which is why it only proposes.
- The Yard's Resurvey Step (code: `kitchen/stations/freshen.ps1`) asks a crew to resolve merge conflicts keeping both sides. Markers, lint and scope are checked without AI, but "both sides kept" cannot be proven; Inspection (code: tests) and the Inspector (code: `taster`) catch the rest, and an unresolved conflict still aborts.
- Freshness is judged from the `Last updated:` stamp in NOW.md, which an agent must keep honest.
- The secret scan is a heuristic and can miss encoded or split secrets.
- v0 does not run by itself; nothing is scheduled yet.
- Hard links cannot be told apart from normal files: they are still scanned (values are still never printed).
- Home crew (code: the `local` cook): the prompt is held to an 8192-token context so the model stays on the graphics card; a very long prompt is truncated by Ollama and quality may drop. A full-size run unloads the decider, so the next routing decision pays a cold start.
- `kitchen/rank-fit.ps1` (job fit) is keyword-based: it cannot tell "required" from "nice to have", counts a skill if the word appears anywhere in the posting, and only the clearance and on-site rules lower the score.
- `handoff.ps1`, `refresh-boot.ps1` and `boot-inject.ps1` read `NOW.md` on their own and are not covered by the link protection above.
- Link tests that need symlink permission print `SKIP` (counted in the `RESULT` line) when the rig cannot create symlinks; junction tests always run.
- Autopilot crew fallback (code: `fallbackCook`): an improve work order resting >2 hours switches remaining non-private steps from `antigravity` to `fallbackCook` (`gemini`, never `claude`); private steps and other assistants wait normally, and if the fallback also rests the standard wait and 60-wait quarantine cap apply.

## Agent Standup integration (added 2026-10-10)
A pinned, unofficial fork of Atoll92/agent-standup (`%USERPROFILE%\source\repos\agent-standup`, commit 2dc346c, no remote, no dependencies) shows agent sessions as a live "team call". Reviewed read-only before install: `gemini-brain/memory/design/agent_standup_review.md`.

| Script | What it does |
|---|---|
| `scripts/standup.ps1 -Action start/stop/status [-Mode demo\|live] [-Port N] [-MaxMinutes N]` | Supervised launcher. Refuses unless the clone is at the pinned commit and clean; refuses a busy port; strips API keys from the server's environment; demo mode serves only the built-in fictional session (empty projects folder); live mode serves real transcripts on localhost (any local process can read them while it runs); auto-stops (default 120 min); stop/status only touch recorded pids. |
| `scripts/standup-recap.ps1 -Port N -Proj P -Id S -OutPath <...\inbox\x.md>` (or `-FromFile`) | Deterministic recap PROPOSAL of one session: agents, delegation titles, tool/error/token counts, 200-char report lines. No user prompts, work order bodies or tool output. Secret-scanned; writes only into a folder named `inbox`. |
| `handoff.ps1` (existing) | The toolbox talk (code: `memory\BOOT.md`) now includes "Agent sessions" from `agent-standup status --json` (read-only CLI, metadata only). |

Rules: never run `node server.js` directly (use `standup.ps1`); keep translation, jokes and music OFF; never start live mode for anything shown to other people (use demo); do not add its statusLine to settings without Jordan's yes. Tests: `tests/Test-Standup.ps1`, `Test-StandupRecap.ps1`, `Test-HandoffStandup.ps1`.

## verify-all (added 2026-10-10)
`pwsh -File scripts\verify-all.ps1` runs every suite in `scripts\verify-all.json` (brain-monitor, my-apps, demo), each bounded by `run-bounded.ps1`, then the Site check (code: `scripts\kitchen-check.ps1`), and prints one line per suite plus `OVERALL: PASS|FAIL`. A glob that matches nothing or a missing folder is a FAIL, never green. Exit 0 = all pass. Test: `tests\Test-VerifyAll.ps1`.

## Code standards (added 2026-10-22)
House rules for this repo's code are in `kitchen/STANDARDS.md` (600-line cap, two-line header, bounded runs, no bare python, no secrets in URLs, PR shape). `pwsh -File scripts\check-standards.ps1` checks the mechanical ones against the ratchet `kitchen/lint-baseline.json` (fails only on new or worse violations; `-WriteBaseline` re-records). `scripts\make-map.ps1` rewrites `kitchen/MAP.md` (every code file, its lines, header and functions). `scripts\dead-code.ps1` lists PowerShell functions named nowhere else in the repo (report only). Test: `tests\Test-Standards.ps1`, run by the tests Step (code: `kitchen\stations\tests.ps1`) on every work order.

## Automatic context handling (added 2026-10-10)
No human step is needed when a session gets long. `~/.claude/settings.json` wires: Context Guard (every prompt and tool call: at 50% "keep working, run refresh-boot soon"; at 65% "compaction is close, refresh and continue"), **PreCompact -> `scripts/refresh-boot.ps1`** (rebuilds `memory/BOOT.md` with zero model tokens, never blocks), **SessionStart -> `scripts/boot-inject.ps1`** (loads the pack as DATA after startup, /clear or compaction; flags it stale after 48 h or missing; never injects a pack that contains secret-shaped text), and built-in auto-compact at 650K tokens (`autoCompactWindow`). Tests: `tests/Test-BootAuto.ps1`, `tests/Test-ContextGuard.ps1`.

## Internal RGB control (added 2026-10-11)
`scripts/rgb.ps1` drives the OMEN rig's internal lighting through the OMEN Light Studio window (Windows UI Automation; needs HP OMEN Gaming Hub, installed 2026-10-11, and a logged-in user). `-Action set -Brightness 0..100`, `install-schedule` (default off 22:00, on 07:00 at 100; current user, not elevated, 5-minute limit, no overlap), `status`, `remove-schedule`. Tasks: `Rig-RGB-Off` / `Rig-RGB-On`. Log: `%LOCALAPPDATA%\brain-rgb\rgb.log`. Change times: rerun `install-schedule -OffAt HH:mm -OnAt HH:mm`. Tests: `tests/Test-Rgb.ps1` (UI part verified by hand). Limit: the schedule only fires while Jordan is logged in; if the PC is asleep at 22:00, StartWhenAvailable runs it on wake.

## Task orchestrator (added 2026-10-26)
A loop that works a pool of numbered task files until it is paused, runs out of work, or runs out of usage. Start it in a Claude Code session in this checkout with `/task-orchestrate` (one lane) or `/task-orchestrate --lanes 2` (up to 4). `/task-start <n>` works one task; `/task-new <brief>` raises a task; `/roadmap-add <brief>` adds a milestone. Tasks can be added at any time and join the pool at the next pick.
- **The task store is local and private, never in this repo.** One `.md` file per task (`0012-short-name.md`) with front matter: `title`, `kind` (task | milestone), `status` (todo, doing, review, blocked, done, dropped), `priority` (1-9, 1 first), `milestone`, `order` (a milestone's place in the roadmap), `paths` (files or globs the task touches), `depends` (task numbers, or `jordan` = needs Jordan at the computer), `public_title` (the only task words allowed in public: the PR title is `WO-TASK-<n>: <public_title>`). Where it is: `--store`, else `$TIDE_TASKS_DIR`, else `{"store": "..."}` in `%LOCALAPPDATA%\brain-kitchen\tasks.json` (or `$BRAIN_KITCHEN\tasks.json`), else `%USERPROFILE%\gemini-brain\projects\tide\tasks`.
- **The CLI** (`node tools/task.mjs`, no packages, Node 22+): `list`, `show <n>`, `next [--lanes N] [--claim] [--resume] [--run new|<id>]`, `start <n>`, `lock acquire|heartbeat|release|status`, `roadmap [--next]`, `new`, `set <n> key=value`, `note <n> --text`, `pause --reason "..."`, `resume`, `state`, `usage`, `check`, `where`; `--json` on every command. Ready = a todo task whose dependencies (and its milestone's) are all done; order = priority, then milestone order, then number. Lanes take several ready tasks only when their `paths` cannot clash (a task with no paths runs alone), never above the WIP limit of 4 open build streams. A malformed file is listed with its reason and never worked; `check` also finds unknown dependencies and cycles.
- **The loop** (`.claude/workflows/task-orchestrate.js`): PICK (haiku runs `next --claim`, or `start <n>` for `/task-start`; both check pause, usage and the lock) -> WORK (the session's model builds in a fresh worktree `<checkout>\..\wt\task-<n>` on branch `task/<n>`, tests first, privacy scan of the lines it adds before every push, noreply identity, `Co-Authored-By` trailer, a PR to main) -> VERIFY (the impacted suites through `kitchen/stations/tests.ps1 -Impacted`, CI, and an independent sonnet reviewer, never the builder, with SHIP / SHIP AFTER FIXES / DON'T SHIP, all pinned to one head commit; a failed suite is never forgotten while CI is pending; fixes go back to the builder for `--rounds N` fix rounds (default 3), then the task gets `depends: jordan` and a note) -> MERGE (Jordan's standing approval: `scripts/merge-pr.ps1 -ExpectHead <reviewed sha>` only after SHIP and green CI, one merge at a time, refused if the PR moved past the reviewed commit; when the merged diff (`gh pr diff --name-only`) touches `pass-app/`, the Board is redeployed with `pass-app/update.ps1`, or a note says why not; a merge refused for a freeze, a red main or CI that never finished makes the task `blocked` + `depends: jordan`) -> GATE (every 3 merges and at the end: privacy scan of the lines the merges added (lines already on main were scanned when they landed and do not block), suites; review notes become one tidy-up task) -> PLAN (when nothing is ready: the next milestone in roadmap order gets the tasks that can start now). Options: `--max N` (default 40: a workflow stops at 1000 agents), `--gate-every N`, `--rounds N`, `--no-plan`.
- **Blocked tasks:** `status: blocked` with a line in the body saying what it waits for (for example a PR that is still open elsewhere); the plan step checks those first and sets them back to todo once that is true.
- **Stops:** `node tools/task.mjs pause --reason "..."` stops it at the next pick (`resume` undoes it). Weekly usage at 95% stops; a full 5-hour window only pauses: every state lives in the task files, so running `/task-orchestrate` again resumes its own in-flight tasks. A privacy problem pauses it for Jordan. **One orchestrator at a time:** the first pick takes `.orchestrator.lock` in the store, every pick, check and merge beats its heartbeat, the end releases it; a second run stops at its first pick, and the lock is a lease: the builder renews it around every suite run and at least every 20 minutes of a long step, and only a lock silent for 90 minutes (a run cut off by a cap) is taken over, and said so (`node tools/task.mjs lock release --force` frees it by hand). It never force-pushes, deletes a branch, or closes, reopens or approves a PR, and it works public repos only (a private repo stops it at the first pick; merge freezes are enforced by `scripts/merge-pr.ps1`).
- **Later:** the `--json` output (shape `v: 1`, no task bodies outside `show`) is meant to be read, read-only, by the L1 ledger as one more source; nothing couples them today.
- Tests: `tests/Test-TaskCli.ps1` (node `tests/tools/test-task.mjs`: the CLI, and the workflow run against a fake `agent()`); also in CI (Core step). Limits: the workflow's first live run (2026-10-27, `docs/changes/task-21.md`) covered pick and build only; its verify, merge, gate and plan steps have run against the fake agent alone; lanes wait for the whole batch before the next pick.
