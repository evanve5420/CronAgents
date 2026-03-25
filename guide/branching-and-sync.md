# Branching & Sync

CronAgents uses a branch-per-user model so multiple people can share the same repository while keeping their agent customizations separate.

## The branch model

```
master                    ← Scaffold: scheduler code, templates, schemas
├── personal-agents/alice          ← Alice's agents and customizations
├── personal-agents/bob            ← Bob's agents and customizations
└── personal-agents/evan  ← Evan's agents and customizations
```

| Content | Branch | Git tracked |
|---------|--------|-------------|
| Scheduler runtime (`scheduler/`, `cronagents.ps1`) | `master` | Yes |
| Global config (`cronagents.json`) | `master` | Yes |
| Schemas (`cronagents.schema.json`, etc.) | `master` | Yes |
| Scaffold agents (feedback-evaluator, run-summarizer) | `master` (`scheduler/agents/`) | Yes |
| Your workload agents (`.cronagents/agents/`) | `personal-agents/<you>` | Yes |
| Runtime data (`.cronstate/`) | Neither | Gitignored |

**Key idea:** `master` holds the shared infrastructure. Your user branch is a superset of `master` that adds your personal agents and customizations. When `master` gets updated (new scheduler features, bug fixes), you merge those changes into your branch.

---

## Auto-bootstrap on install

When you run `cronagents.ps1 install`, the installer automatically creates your user branch:

```powershell
.\cronagents.ps1 install
```

This calls `Initialize-UserBranch` which:

1. Resolves your username (see [username resolution](#username-resolution) below)
2. Checks if `personal-agents/<username>` branch exists
3. If not, creates it from the current position: `git checkout -b personal-agents/<username>`
4. If it exists, checks it out: `git checkout personal-agents/<username>`

The operation is non-destructive — if your working tree has uncommitted changes, it warns and aborts rather than risk losing work.

---

## Username resolution

CronAgents determines your username using this priority order:

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | `cronagents.json` → `versioning.userName` | `"userName": "alice"` |
| 2 | `git config github.user` | `evanve5420` → `evanve5420` |
| 3 | `gh auth status` active account | `evanve5420` → `evanve5420` |
| 4 | `git config user.name` (slugified) | `"Alice Smith"` → `alice-smith` |
| 5 (fallback) | `$env:USERNAME` (Windows) | `ALICE` → `alice` |

**Slugification rules:** lowercase, spaces become hyphens, non-alphanumeric characters stripped, consecutive hyphens collapsed, leading/trailing hyphens trimmed.

To override, set `versioning.userName` in `cronagents.json`:

```json
{
  "versioning": {
    "userName": "alice"
  }
}
```

---

## Syncing from master

When `master` gets updates (new features, bug fixes, template changes), merge them into your branch:

```powershell
.\cronagents.ps1 sync
```

### What happens

1. `git fetch origin master` — get latest changes
2. `git merge origin/master --no-edit` — merge into your branch

### Clean merge

If there are no conflicts, you get the updates immediately:

```
✔ Synced with origin/master (clean merge)
  3 commits merged
```

### Conflict resolution

If your changes conflict with `master`:

1. CronAgents lists the conflicted files
2. If Copilot CLI is available, it attempts **agent-assisted resolution** — a Copilot agent reads the conflicts and produces a merged version
3. If Copilot resolves all conflicts, the merge completes automatically
4. If conflicts remain, the merge is aborted and you resolve manually:

```
⚠ Merge conflicts detected in:
  - .github/agents/daily-review.agent.md
  - cronagents.json

Auto-resolution failed. Resolve manually:
  git merge origin/master
  # fix conflicts
  git add .
  git commit
```

---

## Sync policies

The `versioning.syncPolicy` setting in `cronagents.json` controls how the scheduler handles sync:

| Policy | Behavior |
|--------|----------|
| `"auto"` | Scheduler merges from `origin/master` on each tick. Fully automatic. |
| `"notify"` | Scheduler detects divergence and logs a warning. You sync manually. **(default)** |
| `"manual"` | No automatic checks. You run `cronagents.ps1 sync` when you want. |

```json
{
  "versioning": {
    "syncPolicy": "auto"
  }
}
```

**Recommendation:** Start with `"notify"` (the default). Switch to `"auto"` once you're comfortable that merges won't produce unexpected conflicts.

---

## Branch info

Check your branch status at any time:

```powershell
.\cronagents.ps1 branch
```

Output:

```
Current branch:    personal-agents/alice
Expected branch:   personal-agents/alice
Is user branch:    Yes

Divergence from master:
  Ahead:     12 commits
  Behind:    3 commits
  Last sync: 2024-01-10 14:30:00
```

| Field | Description |
|-------|-------------|
| Current branch | The branch you're on right now |
| Expected branch | The branch CronAgents expects based on your username |
| Is user branch | Whether the current branch matches the expected pattern |
| Ahead | Commits on your branch not in `master` (your changes) |
| Behind | Commits on `master` not in your branch (updates to sync) |
| Last sync | When you last merged from `master` (merge-base timestamp) |

If "Behind" is greater than 0, consider running `cronagents.ps1 sync`.

---

## Feedback commits

When the feedback evaluator edits agent files, those changes are automatically committed if `versioning.autoCommitFeedback` is `true` (the default):

```
feedback: daily-review — Focused security scanning on high-priority areas
```

This creates a clean git history of how your agents evolve based on feedback:

```
* feedback: daily-review — Focused security scanning on high-priority areas
* feedback: daily-review — Added src/utils to search scope
* feedback: security-scan — Reduced false positives for test files
* Initial agent setup
```

To disable:

```json
{
  "versioning": {
    "autoCommitFeedback": false
  }
}
```

When disabled, the evaluator still edits files but doesn't commit. You commit manually when ready.

---

## Common workflows

### First-time setup

```powershell
git clone <repo-url> CronAgents
cd CronAgents
.\cronagents.ps1 install     # Creates personal-agents/<you> branch + Task Scheduler
```

### Staying up to date

```powershell
.\cronagents.ps1 sync        # Merge latest master into your branch
```

### Checking if you need to sync

```powershell
.\cronagents.ps1 branch      # Look at "Behind" count
```

### Switching machines

Your user branch is pushed to the remote. On a new machine:

```powershell
git clone <repo-url> CronAgents
cd CronAgents
git checkout personal-agents/alice     # Your branch already exists remotely
.\cronagents.ps1 install      # Register Task Scheduler on this machine
```

---

## Tips

- **Don't work on `master` directly.** Always be on your `personal-agents/<username>` branch. The installer puts you there automatically.
- **Sync regularly.** Especially after the team pushes scheduler updates to `master`.
- **Review merge results.** Even with auto-sync, check that your agents still work after a merge. Run `cronagents.ps1 doctor` to verify.
- **Feedback commits are safe to push.** They only touch your `.cronagents/agents/` files, which live on your branch.
