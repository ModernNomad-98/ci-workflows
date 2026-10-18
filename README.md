# ci-workflows

Shared GitHub Actions workflows for the `ModernNomad-98` repositories.

## DeepSeek PR review

Reusable workflow `.github/workflows/deepseek-review.yml` posts a Codex-style AI review on
pull requests — **DeepSeek_Sherlock** — using the DeepSeek API (`deepseek-flash`, i.e.
DeepSeek-V4.1-Flash, thinking at max effort). The review tool is a vendored, patched copy of
[hustcer/deepseek-review](https://github.com/hustcer/deepseek-review) v1.21 (MIT) in
[`tools/deepseek-review/`](./tools/deepseek-review/) — every change from upstream is listed in
[`PATCHES.md`](./tools/deepseek-review/PATCHES.md).

Every review ends with a signature line, so a reader always knows what wrote it:

> 🕵️ DeepSeek_Sherlock · model `deepseek-flash` (DeepSeek-V4.1-Flash) · thinking: max · advisory only, not a merge gate · ci-workflows@<sha7>

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
- No checkout of PR code, no PR code execution: the diff is read through the GitHub API. The only
  checkout is this repository's `tools/deepseek-review/` at the pinned tool SHA.
- Advisory only — not a required check and does not gate merges.
- Defaults: model `deepseek-flash`, `thinking: enabled`, `reasoning_effort: max`; lockfiles,
  generated output and vendor files excluded.
- The model's reasoning is never posted to the PR. In the reusable workflow it is written to the
  job log (caller repo, same visibility as the PR); the poller does not log it (this repo is public).
- Very long reviews are cut at 65,000 characters with a `[truncated]` marker; the signature always
  stays. A stalled DeepSeek call fails after 600 s; API errors are printed in the job log.

### Reviewing a repository that cannot carry a caller — the poller

Some repositories forbid what the caller needs. opsflow's `scripts/audit-pr-workflow-safety.mjs`
rejects any PR-capable workflow that references a secret, listens to `issue_comment`, or uses a
reusable-workflow job — by design. For those, `deepseek-poll-review.yml` in **this** repository
reviews their PRs from the outside:

- Runs every 10 minutes (and on `workflow_dispatch`, optionally for one repo / one PR / forced).
- Reads `poll.repos` from `review-config.json`; the central `enabled` / `auto` switches apply.
- For each open, non-draft, unlocked PR: reviews a head SHA once (**auto**), or again when a
  non-bot OWNER / MEMBER / COLLABORATOR comment containing `@deepseek` is newer than the last
  review (**mention**). State is derived from GitHub reviews — nothing is stored.
- Runs the same vendored tool (`tools/deepseek-review/`, from the same commit as the poller);
  the target repository has no workflow file and never holds a key.

Secrets in this repository: `CHAT_TOKEN` (DeepSeek key) and `REVIEW_POLL_TOKEN` — a fine-grained
PAT with, for each polled repo, **Pull requests: Read and write**, **Contents: Read**,
**Metadata: Read**. Reviews post as that token's user; a dedicated machine user keeps them
distinguishable from the owner's own reviews.

Trade-offs: `@deepseek` mentions are answered on the next poll, not instantly; the PAT is one
more credential to rotate; GitHub pauses scheduled workflows in a repository with no commits for
60 days (any commit here — e.g. a switch flip — resets that).

Dry run of the decision logic without posting: put a stub `nu` on `PATH` that echoes its
environment and run `scripts/poll-review.sh` with `GH_TOKEN`, `CHAT_TOKEN`, `REVIEWER_LOGIN`,
`REVIEW_TOOL_DIR`, `CONFIG_FILE` (and optionally `ONLY_REPO` / `ONLY_PR`).

### Fixed: reviews of large diffs used to hang

Upstream v1.21 filters the diff with `$content | try { ^awk … }`; Nushell 0.114–0.116 deadlock on
that once awk's output passes ~64 KB, so reviews of large PRs hung until the job timeout
(Project-Aegis #844–#847, waypoint-pm #120). Patch P1 in `PATCHES.md` runs awk on a temp file and
reads it with `complete`; the exclusions were then turned back on.

### Releasing a tool change

GitHub exposes no context for a reusable workflow's own commit, so the tool is pinned by literal
SHA, exactly like an external action — which takes two commits:

1. Change `tools/deepseek-review/` (and `PATCHES.md`), commit and push. Note the SHA.
2. Set `SHERLOCK_TOOL_SHA` in `.github/workflows/deepseek-review.yml` to that SHA, commit and push.
3. Re-pin each caller's `uses:` to the commit from step 2 (the poller needs nothing — it runs
   from `main`).

### Bumping the reusable workflow

1. Edit `.github/workflows/deepseek-review.yml` and merge to `main`.
2. Tag the release (e.g. `git tag v1.1.0 && git push origin v1.1.0`).
3. In each caller, update the pinned SHA + trailing version comment (the callers are identical
   apart from the header, so the diff is reviewable side by side).

### Security

- Every external action and the vendored tool are pinned to full commit SHAs; update the tool
  deliberately after reviewing the upstream diff (`PATCHES.md`, "Updating from upstream").
- `CHAT_TOKEN` is a DeepSeek API key with no GitHub access; it is passed only to the review step
  and masked in logs. The tool never prints request headers.
- `pull_request_target` grants the caller a write-scoped `GITHUB_TOKEN`; the reusable workflow
  only reads the PR and posts a review.
