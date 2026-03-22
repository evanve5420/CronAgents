# Agent Versioning — Git Branch Model for User Agent Customizations

**Status:** Day 0 requirement
**Scope:** How user-created agent/skill/instruction files are version-controlled, backed up, and kept in sync with scaffold updates.

---

## Problem

The feedback evaluator edits agent, skill, and instruction files based on human feedback. Without version control on those files, there's no way to:

1. **Revert a bad edit** — the evaluator oversimplifies a prompt or removes a nuanced instruction
2. **Recover from poisoned feedback** — malicious or careless feedback causes the evaluator to corrupt an agent definition
3. **Trace drift** — many small edits accumulate until an agent behaves nothing like the original, with no history of how it got there
4. **Update the scaffold** — master gets improvements, but users on personal branches can't easily adopt them

CronAgents is intended for sharing with coworkers and potentially open-sourcing. Personal agents must not land on `master`.

---

## Design: Per-User Long-Running Branches

### Branch model

```
master                    ← scaffold code, templates, scaffold agents. Shared/public-safe.
├── agents/evan           ← Evan's customizations layered on top of master
├── agents/alice          ← Alice's customizations layered on top of master
└── agents/bob            ← Bob's customizations layered on top of master
```

- `master` contains all scaffold runtime code (`scheduler/`, `chronagents.ps1`, configs, templates, tests, docs) plus scaffold-internal agents (`scheduler/agents/`). No user-specific agent definitions.
- `agents/<username>` branches are **supersets** of master: they contain everything on master plus the user's personal agent/skill/instruction files under `.chronagents/agents/` and related directories.
- User branches diverge from master **only** in the customization directories. Scaffold code is never edited on user branches (unless intentionally, which creates a legitimate merge conflict).

### What lives where

| Content | Branch | Tracked? |
|---------|--------|----------|
| Scaffold runtime (`scheduler/`, `chronagents.ps1`, etc.) | `master` | Yes |
| Scaffold agents (feedback-evaluator, dashboard-summarizer) | `master` (in `scheduler/agents/`) | Yes |
| Templates/examples | `master` (in `templates/`) | Yes |
| Tests, docs, config schema | `master` | Yes |
| User workload agents (`.chronagents/agents/`) | `agents/<user>` | Yes (on user branch) |
| User skill/instruction overrides | `agents/<user>` | Yes (on user branch) |
| Run data (`.chronagents/runs/`) | Neither | Gitignored on all branches |
| Runtime state (`state.json`) | Neither | Gitignored on all branches |

### Why supersets, not separate trees

User branches are supersets of master (scaffold + customizations), not disconnected branches with only agent files. This means:

- `git merge master` brings scaffold updates into the user branch cleanly because the scaffold files are shared lineage
- The sync script itself lives in `scheduler/` on master and is always current — **no self-update paradox** where a stale sync script can't update itself
- Users can run the full project from their branch — everything is present

---

## Auto-Bootstrap

On first run (or `chronagents.ps1 install`), the scheduler detects branch state and bootstraps automatically:

```
Start-CronAgents.ps1 / chronagents.ps1 install
  → Does agents/<user> branch exist?
    → No:  git checkout -b agents/<user> from master
    → Yes: git checkout agents/<user>
  → Continue with normal startup
```

**Username resolution** (in priority order):
1. `userName` field in `chronagents.json` (explicit config)
2. `git config user.name` (slugified: lowercased, spaces → hyphens, non-alphanumeric stripped)
3. `$env:USERNAME` (fallback)

The bootstrap is **non-destructive**: it never force-pushes, never deletes branches, never resets. If the working tree has uncommitted changes, it warns and aborts rather than risking data loss.

---

## Feedback-Commit Hook

After the feedback evaluator edits files and writes `feedback-result.md`, the **scheduler** (not the evaluator) performs:

```powershell
git add .chronagents/agents/ <any other edited paths from changelog>
git commit -m "feedback: <agent-name> — <one-line summary>"
```

The evaluator doesn't need git awareness. It edits files as it does today. The scheduler reads the changelog from `feedback-result.md` to determine which files changed and constructs the commit.

**Failure handling:**
- If `git add` or `git commit` fails (e.g., permissions, lock file, disk full), the scheduler logs the failure and surfaces it in the dashboard and TUI.
- The files are still edited on disk — only the commit failed. The user can manually commit or the next feedback cycle will pick up the uncommitted changes.
- Pre-edit snapshots (option A, see below) are written **before** the edit attempt, so they exist regardless of git state.

---

## Sync: Merging Scaffold Updates from Master

A **sync** operation merges `master → agents/<user>` to bring scaffold improvements into the user's branch.

### Sync policies

Configured via `syncPolicy` in `chronagents.json`:

| Policy | Behavior | Default? |
|--------|----------|----------|
| `auto` | Merge master → user branch automatically between scheduler ticks. On conflict, pause sync and flag in dashboard/TUI. | No |
| `notify` | Check for divergence on each scheduler startup, report in dashboard/TUI (`N commits behind master`). User triggers merge manually. | **Yes** |
| `manual` | No automatic checking. User runs `chronagents.ps1 sync` explicitly. | No |

### Sync execution

The sync is a **deterministic script** (no LLM), not an agent:

```powershell
# Happy path — fast, free, no tokens
git fetch origin master
git merge origin/master --no-edit
```

If the merge succeeds cleanly (expected for most updates since users don't edit scaffold files), it commits automatically and continues.

### Conflict resolution

If `git merge` fails with conflicts:

1. The sync script records the conflict state (which files, conflict markers)
2. It invokes Copilot CLI with a focused prompt:
   ```
   copilot -p "Resolve these git merge conflicts. The scaffold (master) changes are...
   The user's customizations are... Preserve the user's intent while adopting
   the scaffold improvement." --share=<run-dir>/session.md
   ```
3. If the agent resolves all conflicts, the script stages and commits
4. If conflicts remain, the script aborts the merge (`git merge --abort`), logs the failure, and notifies the user via dashboard/TUI to resolve manually

**Script for the happy path, agent for conflicts.** Clean merges are free. Only conflicts burn tokens.

### Sync timing

- `auto` policy: Sync runs **between scheduler ticks**, before the feedback sweep. This ensures scaffold code is current before any agents run.
- The scheduler does **not** sync while an agent is mid-execution.
- VS Code file watchers will pick up changes automatically. The dashboard notes when a sync occurred.

---

## Pre-Edit Snapshots (Option A)

Regardless of git branching, the feedback evaluator **always** creates pre-edit snapshots:

```
.chronagents/runs/<timestamp>_<agent>/
├── backup/
│   ├── daily-review.agent.md    ← copy of file before evaluator edited it
│   └── review-skill/SKILL.md   ← copy of file before evaluator edited it
├── output.md
├── meta.json
├── feedback.md
├── feedback-result.md
└── ...
```

The `backup/` subdirectory mirrors the relative paths of edited files.

**Why keep both snapshots and git history?**
- Snapshots serve a different timescale: immediate "undo this specific feedback edit" without knowing git
- Snapshots survive even if git operations fail
- Snapshots are paired with the feedback that caused the change (readable in context)
- Git history serves the long-term view: "what happened to this agent over months"
- Snapshots are subject to `retentionDays` cleanup; git history is permanent

---

## CLI Integration

### New subcommands

| Command | Behavior |
|---------|----------|
| `chronagents.ps1 sync` | Manually trigger merge from master. Reports clean merge or conflict status. |
| `chronagents.ps1 branch` | Show current branch, commits ahead/behind master, last sync date. |

### Updated subcommands

| Command | Change |
|---------|--------|
| `status` | Shows current branch, commits behind master (if `notify` or `auto` policy) |
| `doctor` | Verifies user is on expected `agents/<user>` branch. Warns if on master with customizations. Warns if branch is significantly behind master. |

### TUI integration

The interactive menu gains sync awareness:

```
CronAgents (branch: agents/<user>, 3 behind master)
──────────────────────────
 1) Status & upcoming runs
 2) Trigger ad-hoc run
 3) Pause / Resume
 4) View run history
 5) Submit feedback
 6) Health check (doctor)
 7) Sync from master
 8) Branch info
 9) Exit
──────────────────────────
Select [1-9]:
```

---

## Configuration

New fields in `chronagents.json`:

```jsonc
{
  // Existing fields...

  "versioning": {
    "syncPolicy": "notify",        // "auto" | "notify" | "manual"
    "userName": null,               // Override for branch name. null = auto-detect.
    "autoCommitFeedback": true,     // Commit after feedback evaluator edits. Default true.
    "branchPrefix": "agents"       // Branch naming: <prefix>/<userName>. Default "agents".
  }
}
```

All fields are optional with sensible defaults. A user who never touches this section gets `notify` sync policy, auto-detected username, auto-committed feedback edits, and `agents/` prefix.

---

## Testing

### Unit tests (`AgentVersioning.Tests.ps1`)

Test the versioning helper functions in isolation using temp git repos. No Copilot CLI needed.

- **Branch detection**: Given a temp repo with various branch states, verify `Get-CronAgentsBranch` correctly identifies current branch and whether it matches the expected `agents/<user>` pattern
- **Username resolution**: Test priority chain — explicit config → `git config user.name` (with slugification edge cases: spaces, special chars, unicode) → `$env:USERNAME` fallback
- **Divergence calculation**: Given a temp repo where master is N commits ahead, verify `Get-BranchDivergence` returns correct ahead/behind counts
- **Commit message formatting**: Verify feedback commits produce structured messages from changelog input
- **Config defaults**: Verify missing `versioning` block defaults to `notify` / auto-detect / `true` / `agents`

### Integration tests (`SyncWorkflow.Tests.ps1`)

Test full sync and bootstrap workflows against temp git repos with mock Copilot CLI.

- **Auto-bootstrap (no branch exists)**: Init temp repo with only master. Run bootstrap. Verify `agents/<user>` branch created from master HEAD, working tree on new branch.
- **Auto-bootstrap (branch exists)**: Init temp repo with existing `agents/<user>` branch. Run bootstrap. Verify checkout to existing branch, no duplicate branch created.
- **Auto-bootstrap (dirty working tree)**: Init temp repo with uncommitted changes. Run bootstrap. Verify it warns and aborts, no data loss.
- **Clean merge**: Create temp repo. Add commits to master after user branch diverges. Run sync. Verify merge succeeds, user customization files preserved, scaffold files updated.
- **Conflict merge (agent-assisted)**: Create temp repo where master and user branch both edit the same file. Run sync with mock copilot that "resolves" conflicts. Verify merge completes with agent's resolution.
- **Conflict merge (agent fails)**: Same as above but mock copilot leaves conflicts. Verify `git merge --abort` is called, user notified, no corrupted state.
- **Feedback-commit hook**: Edit files as the feedback evaluator would, run the commit hook. Verify correct files staged, commit message formatted from changelog, commit exists in branch history.
- **Feedback-commit failure**: Simulate `git commit` failure (e.g., lock file). Verify files remain edited on disk, failure logged, dashboard notified, pre-edit snapshots still exist.

### Pre-edit snapshot tests (`BackupRestore.Tests.ps1`)

- **Snapshot creation**: Run feedback evaluator mock that edits two files. Verify `backup/` directory in run dir contains exact copies of both files pre-edit.
- **Snapshot path mirroring**: Edit files at nested paths (`.chronagents/agents/nested/deep/agent.md`). Verify backup preserves the relative path structure.
- **Snapshot survives git failure**: Simulate git commit failure after backup. Verify snapshots exist and are readable.
- **Retention cleanup preserves recent backups**: Run retention cleanup. Verify backups in recent run dirs survive, backups in expired (and feedback-processed) run dirs are cleaned up.

### Test isolation

All versioning tests create **temp git repos** (`New-TemporaryFile` → `git init`) and clean up in `AfterAll`/`finally`. They never touch the real CronAgents repo, the user's global git config, or any real branches. The tests use `GIT_DIR` / `GIT_WORK_TREE` env vars or `git -C <path>` to scope all git operations to the temp directory.

---

## Open Questions

1. **Push policy**: Should the scheduler push user branches to the remote? This enables backup and multi-machine sync but raises the "personal agents visible on remote" concern. Options: never push (local only), push to a separate private remote, or push to origin but rely on branch protection to keep master clean. Day 0 recommendation: **local only** — pushing is opt-in future work.

2. **Multiple machines**: If the same user runs CronAgents on two machines, their `agents/<user>` branches diverge locally. Without pushing/pulling, they're independent. This is acceptable for day 0 but worth noting.

3. **Agent file locations outside the repo**: User agents in `~/.copilot/agents/` (user-global Copilot directory) are outside the git repo entirely. The branching model can't version those. Pre-edit snapshots (option A) are the only safety net for user-global agents.

4. **Branch cleanup**: If a user is removed from the team, their `agents/<user>` branch lingers. Not a day-0 concern but worth a `chronagents.ps1 prune-branches` command eventually.
