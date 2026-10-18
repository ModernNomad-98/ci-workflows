# ci-workflows

Shared GitHub Actions workflows for the `ModernNomad-98` repositories.

## DeepSeek PR review

Reusable workflow `.github/workflows/deepseek-review.yml` posts a Codex-style AI review on
pull requests using [hustcer/deepseek-review](https://github.com/hustcer/deepseek-review)
(MIT, pinned to the v1.21 commit `eccde2e`) and the DeepSeek API.

Each repository carries a small caller workflow named **DeepSeek Code Review** that pins this
workflow by full commit SHA — see [`caller-template.yml`](./caller-template.yml). Current callers:
`waypoint-pm`, `Project-Aegis`, `opsflow`.

**Why this repository is public:** GitHub only lets a *public* caller repository
(`Project-Aegis`) call a *public* reusable workflow. There are no secrets in this repository —
every caller passes its own `CHAT_TOKEN`.

### Central switches — `review-config.json`

The reusable workflow's gate job reads [`review-config.json`](./review-config.json) at run time, so
the switches below apply **even to callers pinned by SHA**:

```json
{ "enabled": true, "auto": true }
```

| Change | Effect |
| --- | --- |
| `"enabled": false` | **hold** every review in every caller |
| `"auto": false` | **mention-only** everywhere: automatic PR reviews stop, `@deepseek` still works |
| `"auto": true`, `"enabled": true` | normal behaviour |

Use the helper (commits the JSON change to `main` for you):

```powershell
pwsh ./review.ps1 -Action status
pwsh ./review.ps1 -Action hold            # stop all reviews
pwsh ./review.ps1 -Action resume          # re-enable
pwsh ./review.ps1 -Action mention-only    # automatic off, @mention on
```

A config fetch failure holds reviews (fail closed). Flipping values in the JSON, committing and
pushing to `main` is the whole process — no workflow edit and no caller bump.

### Set up a repository

1. Copy `caller-template.yml` to `.github/workflows/deepseek-code-review.yml`; replace the
   pinned `uses:` SHA with the current `main` commit of this repo (and the version comment), and
   replace `<OWNER>/<REPO>` in the header.
2. Add the API key as a repository secret:
   ```sh
   gh secret set CHAT_TOKEN -R OWNER/REPO        # paste a DeepSeek API key
   ```
   Create one at https://platform.deepseek.com → API keys (shown once; needs balance).
3. Merge the caller PR. `pull_request_target` runs the base branch's workflow files, so the
   caller does not execute from its own PR.

### Per-repository switches

| Scope | How | Effect |
| --- | --- | --- |
| One repo, immediate | `gh workflow disable "DeepSeek Code Review" -R OWNER/REPO` | that repo stops; `gh workflow enable` reverses |
| One repo, no code change | `gh variable set DEEPSEEK_REVIEW_ENABLED --body false -R OWNER/REPO` | caller job skips; unset or `true` re-enables |
| One repo, permanent | delete `.github/workflows/deepseek-code-review.yml` via PR | gone; optionally delete the `CHAT_TOKEN` secret |
| Everything | central `"enabled": false`, then remove callers and delete/archive this repo | inert |

Helper for per-repo actions:

```powershell
pwsh ./review.ps1 -Action status
pwsh ./review.ps1 -Action disable -Repos waypoint-pm,Project-Aegis
pwsh ./review.ps1 -Action enable
```

### Behaviour

- Triggered by the caller on `pull_request_target` (`opened`, `reopened`, `synchronize`,
  `ready_for_review`, base `main`); draft PRs are skipped.
- `issue_comment` containing `@deepseek` re-reviews; only OWNER / MEMBER / COLLABORATOR
  comments reach the reusable workflow.
- Posts a formal PR review; `skip review` / `skip cr` in the PR title or body skips a run;
  locked conversations are skipped.
- No checkout, no PR code execution: the diff is read through the GitHub API.
- Advisory only — not a required check and does not gate merges.
- Defaults: `deepseek-v4-flash`, lockfiles/generated output/vendor excluded.

### Bumping the reusable workflow

1. Edit `.github/workflows/deepseek-review.yml` and merge to `main`.
2. Tag the release (e.g. `git tag v1.1.0 && git push origin v1.1.0`).
3. In each caller, update the pinned SHA + trailing version comment (the callers are identical
   apart from the header, so the diff is reviewable side by side).

### Security

- The review action and the lookalike callers are pinned to full commit SHAs; bump deliberately
  after reviewing the upstream diff.
- `CHAT_TOKEN` is a DeepSeek API key with no GitHub access; it is passed only to the pinned
  action and masked in logs.
- `pull_request_target` grants the caller a write-scoped `GITHUB_TOKEN`; the reusable workflow
  only reads the PR and posts a review.
