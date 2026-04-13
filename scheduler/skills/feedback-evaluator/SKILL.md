---
name: feedback-evaluator
description: "Evaluation procedures for processing human feedback on agent runs"
---

# Feedback Evaluator Skill

## Purpose

This skill provides the feedback evaluator agent with procedures and reference material for processing human feedback and making appropriate edits to agent definitions.

## Evaluation Procedures

### 1. Read and Understand Feedback

- Read `feedback.md` from the run directory
- Read `output.md` and `meta.json` to understand what the agent did
- Identify the specific improvements the human is requesting
- **Check for a `## Target` section** — if present, this determines which agent the feedback applies to

### 2. Resolve Feedback Target

Determine which agent the feedback is for:

| Scenario | Action |
|----------|--------|
| Explicit `## Target` with `agent:` and `files:` | Edit ONLY those files |
| Explicit `## Target` with `agent:` only | Look up files in `subagents.json` manifest |
| No target, single-agent run | Apply to the agent in `meta.json` (default) |
| No target, orchestrator run, clear inference | Apply to the inferred subagent |
| No target, orchestrator run, ambiguous | Write no-op note, make no edits |

**Resolving against the manifest:** If `subagents.json` exists in the run directory, match `agent: <name>` to the manifest entry's `name` or `agent` field. Use the entry's `profile` and `skills` to find the files to edit.

**When `files:` is specified in the target**, those override whatever the manifest says — the human knows best.

### 3. Assess Scope

Determine which files need changes:
- **Agent definition** (`.agent.md`) — system prompt, tool scoping, model selection
- **Skill files** (`SKILL.md`) — domain knowledge, procedures, reference material
- **Instruction files** — workspace or global instructions

### 4. Make Targeted Edits

- Change only what the feedback specifically asks for
- Preserve existing structure, frontmatter format, and conventions
- Keep changes minimal — don't rewrite entire files
- If the feedback is about output quality, adjust the system prompt
- If the feedback is about tool usage, adjust the `tools` frontmatter or deny rules
- If the feedback is about domain knowledge, update the relevant `SKILL.md`

### 5. Document Changes

Write `feedback-result.md` in the run directory with:
- List of files changed with before/after descriptions
- Rationale for each change
- One-line summary suitable for a git commit message

For no-op results (ambiguous or unresolvable target), write:
- Clear explanation of why no edits were made
- Guidance on how to re-submit with an explicit target

### 6. Boundaries

**Can edit:** `.agent.md` files, `SKILL.md` files, instruction files, memory files
**Cannot edit:** Scheduler scripts, config schemas, `feedback-evaluator.agent.md` itself, `cronagents.ps1`
**Cannot delete:** Any files

## Common Feedback Patterns

| Feedback | Typical Edit |
|----------|-------------|
| "Too verbose" | Tighten system prompt, add conciseness instruction |
| "Missing context" | Add relevant search patterns or file references to prompt |
| "Wrong tools" | Adjust `tools` frontmatter in `.agent.md` |
| "Too aggressive edits" | Add caution instructions, reduce edit scope |
| "Not finding the right files" | Add search patterns or explicit paths to skill |
| "Unclear or contradictory" | Note in feedback-result.md, make no edits |

## Target Format Reference

The `## Target` section in feedback.md uses this format:

```markdown
## Target
agent: <agent-name>
files:
- path/to/file1
- path/to/file2

## Feedback
<feedback text>
```

- `agent:` (required in target) — the subagent name to target
- `files:` (optional) — explicit file list; overrides manifest lookup
- The `## Feedback` heading is optional but recommended for clarity

## Subagent Manifest Reference

`subagents.json` in the run directory declares spawned subagents:

```json
[
  {
    "name": "worker",
    "agent": "worker",
    "profile": ".github/agents/worker.agent.md",
    "skills": [".github/skills/worker/SKILL.md"]
  }
]
```

Use this to resolve `agent: <name>` when the feedback target does not include `files:`.
