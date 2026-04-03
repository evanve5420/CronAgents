---
name: posting-pr-comments
description: "Use when asked to post a comment to a specific GitHub pull request. Covers GitHub CLI checks and the comment workflow."
argument-hint: "Describe the PR number or URL and the comment to post"
---

# Posting PR Comments

Use `gh pr comment` to add a conversation comment to an existing pull request.

## Inspect The PR

Inspect the PR before posting:

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
 $bodyPath = [System.IO.Path]::GetTempFileName()
try {
   @"
Addressed the review feedback.

- Updated the runner
- Revalidated the suite
"@ | Set-Content -Path $bodyPath -Encoding UTF8

   gh pr comment <pr-number> --body-file $bodyPath
}
finally {
   Remove-Item -Path $bodyPath -ErrorAction SilentlyContinue
}
```

## Guardrails

- Do not claim a comment was posted unless the `gh pr comment` command succeeded.
- If the user asks for a line-specific review comment, `gh pr comment` is not enough; that requires a review workflow rather than a general PR conversation comment.
