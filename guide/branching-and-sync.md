# Branching & Sync

CronAgents uses a simple two-repo model: a shared **infra repo** for scheduler code and a **personal repo** for each user's agent definitions.

## The model

```
Infra repo (shared)           ← Scheduler code, templates, schemas, docs
  └── master / feature branches   ← All shared development

Personal repo (~/.cronagents/)  ← Your agents, registrations, runtime state
  └── single branch (main)        ← No branching needed
```

| Content | Location | Git tracked |
|---------|----------|-------------|
| Scheduler runtime (`scheduler/`, `cronagents.ps1`) | Infra repo | Yes |
| Global config (`cronagents.json`) | Infra repo (base) + personal repo (overrides) | Yes |
| Schemas (`cronagents.schema.json`, etc.) | Infra repo | Yes |
| Scaffold agents (feedback-evaluator, run-summarizer) | Infra repo (`.github/agents/`) | Yes |
| Your workload agents (`.github/agents/`, `.cronagents/agents/`) | Personal repo (`~/.cronagents/`) | Yes |
| Skills for your agents (`.github/skills/`) | Personal repo (`~/.cronagents/`) | Yes |
| Runtime data (`.cronstate/`) | Personal repo | Gitignored |

**Key idea:** Shared infrastructure lives in the infra repo on `master`. Your personal agents live in a completely separate git repository at `~/.cronagents/`. No branch switching, no sync, no merge conflicts.

---

## Personal repo initialization

When you run `cronagents.ps1 install`, the installer creates your personal repo:

```powershell
.\cronagents.ps1 install
```

This calls `Initialize-PersonalRepo` which:

1. Resolves the personal repo path from `personalRepo.path` (default `~/.cronagents/`)
2. Creates the directory structure if it doesn't exist
3. Initializes a git repository
4. Sets up `.github/agents/`, `.cronagents/agents/`, `.github/skills/`, and `.cronstate/`

---

## Username resolution

CronAgents determines your username using this priority order:

| Priority | Source | Example |
|----------|--------|---------|
| 1 (highest) | `cronagents.json` → `personalRepo.userName` | `"userName": "alice"` |
| 2 | `git config github.user` | `alice` |
| 3 | `gh auth status` active account | `alice` |
| 4 | `git config user.name` (slugified) | `"Alice Smith"` → `alice-smith` |
| 5 (fallback) | `$env:USERNAME` (Windows) | `ALICE` → `alice` |

To override, set `personalRepo.userName` in `cronagents.json`:

```json
{
  "personalRepo": {
    "userName": "alice"
  }
}
```

---

## Shared development workflow

All shared development happens in the infra repo on `master` or feature branches:

```powershell
cd CronAgents                   # infra repo
git checkout master
git checkout -b feat/my-change  # optional feature branch
# make changes
./tests/Invoke-Tests.ps1        # validate
git commit
git checkout master && git merge feat/my-change
```

No sync step is needed afterward — the personal repo is independent.

---

## Feedback commits

When the feedback evaluator edits agent files, those changes are automatically committed in the personal repo if `personalRepo.autoCommitFeedback` is `true` (the default):

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
  "personalRepo": {
    "autoCommitFeedback": false
  }
}
```

---

## Config layering

CronAgents supports configuration in both repos:

1. **Infra repo** `cronagents.json` — base settings shared by the team
2. **Personal repo** `cronagents.json` — user-specific overrides

Personal repo settings are merged on top of infra repo settings. This lets the team set defaults while each user customizes their own experience.

---

## Common workflows

### First-time setup

```powershell
git clone <repo-url> CronAgents
cd CronAgents
.\cronagents.ps1 install     # Creates personal repo + Task Scheduler
```

### Switching machines

The personal repo is local. On a new machine:

```powershell
git clone <repo-url> CronAgents
cd CronAgents
.\cronagents.ps1 install     # Creates fresh personal repo on this machine
```

To transfer agents, copy `~/.cronagents/` from your other machine, or push/pull the personal repo to a remote.

---

## Tips

- **Never put personal agents in the infra repo.** They belong in `~/.cronagents/`.
- **Feedback commits are safe.** They only touch files in the personal repo.
- **No sync needed.** The personal repo is independent of the infra repo's branches.
