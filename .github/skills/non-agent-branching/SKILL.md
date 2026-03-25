---
name: non-agent-branching
description: "Describe and apply the branch workflow for non-agent development in this repository"
---

# Non-Agent Branching

Use this skill when the work is about shared repository development rather than personal agent customization.

Examples:
- scheduler or CLI changes
- tests
- docs
- schemas
- templates
- shared skills under `scheduler/skills/`

## Read First

1. [guide/branching-and-sync.md](../../../guide/branching-and-sync.md)
2. [docs/AGENT-VERSIONING.md](../../../docs/AGENT-VERSIONING.md)

## Core Rule

`personal-agents/<user>` branches are for user-specific agent customizations.

Shared repo development belongs on `master` or on a short-lived feature branch created from `master`, then merged back to `master`.

If the requested work changes shared infrastructure, do **not** leave it only on a personal branch.

## Workflow

### 1. Classify the change

Use the personal branch only for tracked personal agent content such as:
- `.cronagents/agents/`
- `.github/agents/` when it is a user-specific agent
- personal feedback-driven agent evolution

Use `master` / feature branch for shared development such as:
- `cronagents.ps1`
- `scheduler/`
- `tests/`
- `guide/`
- `docs/`
- schemas and templates

### 2. Move to the right branch before editing

If you are on `personal-agents/<user>` and the task is shared repo development:

1. Check whether the working tree is clean.
2. If it is not clean, stop and explain what must be committed, stashed, or moved first.
3. Switch to `master`, or create a feature branch from `master` for the work.

Typical flow:

```powershell
git checkout master
git pull --ff-only origin master
# optional
git checkout -b feat/<short-topic>
```

### 3. Make and validate the change

For shared repo changes:

```powershell
./tests/Invoke-Tests.ps1
```

Prefer the existing shared module and helpers instead of duplicating logic.

### 4. Land the change on master

If you used a feature branch:

1. Commit there.
2. Merge or fast-forward it into `master`.
3. Push `master`.

The goal is that shared development ends up on `master`, not stranded on a personal branch.

### 5. Refresh your personal branch afterward

If you also use a personal branch for scheduled agents:

```powershell
git checkout personal-agents/<user>
.\cronagents.ps1 sync
```

If scheduler startup or install behavior changed, also re-run:

```powershell
.\cronagents.ps1 install
.\cronagents.ps1 doctor
```

## Guardrails

- Do not commit generated runtime artifacts such as `.cronstate/`
- Do not keep shared scheduler or CLI fixes only on `personal-agents/<user>`
- Do not edit on `master` when the work is actually personal agent customization
- When in doubt, ask: "Is this shared infrastructure or personal agent state?"
