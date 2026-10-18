# ci-workflows

Shared GitHub Actions workflows for the `ModernNomad-98` repositories.

## DeepSeek PR review

Reusable workflow `.github/workflows/deepseek-review.yml` posts a Codex-style AI review on
pull requests using [hustcer/deepseek-review](https://github.com/hustcer/deepseek-review)
(MIT, pinned to the v1.21 commit `eccde2e`) and the DeepSeek API.

Each repository carries a small caller workflow named **DeepSeek Code Review** — see
[`caller-template.yml`](./caller-template.yml). Current callers: `waypoint-pm`,
`Project-Aegis`, `opsflow`.

**Why this repository is public:** GitHub only lets a *public* caller repository
(`Project-Aegis`) call a *public* reusable workflow. There are no secrets in this
repository — every caller passes its own `CHAT_TOKEN`.

### Set up a repository

1. Copy `caller-template.yml` to `.github/workflows/deepseek-code-review.yml` and replace
   `<OWNER>/<REPO>` in the header comment.
2. Add the API key as a repository secret:
   ```sh
   gh secret set CHAT_TOKEN -R OWNER/REPO        # paste a DeepSeek API key
   ```
   Create one at https://platform.deepseek.com → API keys (shown once; needs balance).
3. Merge the caller PR. `pull_request_target` runs the base branch's workflow files, so the
   caller does not execute from its own PR.

### Turning it off

| Scope | How | Effect |
| --- | --- | --- |
| All repos — mention-only | in `deepseek-review.yml`, set `auto` input default to `false` and commit to `main` | automatic reviews stop; `@deepseek` mentions still review |
| All repos — fully off | same file, set `enabled` input default to `false` and commit to `main` | review job skips in every repo on its next trigger; revert to re-enable |
| One repo — immediate | `gh workflow disable "DeepSeek Code Review" -R OWNER/REPO` | that repo stops; `gh workflow enable` reverses it |
| One repo — no code change | `gh variable set DEEPSEEK_REVIEW_ENABLED --body false -R OWNER/REPO` | caller job skips; unset or set `true` to re-enable |
| One repo — permanent | delete `.github/workflows/deepseek-code-review.yml` via PR | gone; optionally delete the `CHAT_TOKEN` secret |
| Everything | remove callers, then delete/archive this repository | inert |

Helper (from a clone of this repo):

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

### Security

- The review action is pinned by commit SHA; bump deliberately after reviewing the upstream
  diff.
- `CHAT_TOKEN` is a DeepSeek API key with no GitHub access; it is passed only to the pinned
  action and masked in logs.
- The central `enabled` / `auto` defaults are the account-wide switches; editing them in
  this repository affects every caller on its next trigger.
- `pull_request_target` grants the caller a write-scoped `GITHUB_TOKEN`; the reusable
  workflow only reads the PR and posts a review.
