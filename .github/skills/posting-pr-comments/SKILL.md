---
name: posting-pr-comments
description: "Use when asked to post a comment to a specific GitHub pull request. Covers GitHub CLI checks and the comment workflow."
argument-hint: "Describe the PR number or URL and the comment to post"
---

# Posting PR Comments

Use `gh pr comment` to add a conversation comment to an existing pull request.

## Preconditions

Verify these first:

1. `gh` is installed:
   ```powershell
   gh --version
   ```
2. `gh` is authenticated:
   ```powershell
   gh auth status
   ```
3. The current repo matches the PR's repository remote:
   ```powershell
   git remote -v
   ```

If `gh` is missing or not authenticated, stop and tell the user what is missing instead of pretending the comment was posted.

## Inspect The PR

Look at the PR before posting so the comment is anchored to the right context:

```powershell
gh pr view <pr-number> --comments
```

You can use either a PR number such as `30` or a full URL such as `https://github.com/owner/repo/pull/30`.

## Post The Comment

For short comments:

```powershell
gh pr comment <pr-number> --body "<comment text>"
```

For multi-line comments, prefer a here-string or body file to avoid shell quoting issues:

```powershell
$body = @"
Addressed the review feedback.

- Updated the runner
- Revalidated the suite
"@

gh pr comment <pr-number> --body $body
```

If the comment is long or generated programmatically, write it to a temporary file and use `--body-file`:

```powershell
$bodyPath = Join-Path $env:TEMP 'cronagents-pr-comment.md'
@"
Addressed the review feedback.

- Updated the runner
- Revalidated the suite
"@ | Set-Content -Path $bodyPath -Encoding UTF8

gh pr comment <pr-number> --body-file $bodyPath
```

## Good Workflow

1. Confirm the target PR.
2. Inspect existing comments with `gh pr view <pr> --comments`.
3. Post the comment with `gh pr comment <pr> --body ...`.
4. Report success back to the user with the PR number and a short summary of what was posted.

## Guardrails

- Do not claim a comment was posted unless the `gh pr comment` command succeeded.
- Prefer `--body-file` for long comments or content containing quotes, backticks, or Markdown blocks.
- Keep the comment specific: mention what changed, what was validated, and any remaining limitation.
- If the user asks for a line-specific review comment, `gh pr comment` is not enough; that requires a review workflow rather than a general PR conversation comment.

## Examples

Post to PR `30` in the current repo:

```powershell
gh pr comment 30 --body "Rebased on master and re-ran ./tests/Invoke-Tests.ps1."
```

Inspect then comment using a full URL:

```powershell
gh pr view https://github.com/owner/repo/pull/30 --comments
gh pr comment https://github.com/owner/repo/pull/30 --body "Addressed the requested follow-up changes."
```