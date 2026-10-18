#!/usr/bin/env bash
# DeepSeek PR review — external poller.
#
# Reviews open pull requests in OTHER repositories by calling the GitHub API with a scoped
# token, so the target repository needs no workflow file and never holds the DeepSeek key.
# Built for repositories (e.g. opsflow) whose PR-workflow safety audit forbids secrets,
# issue_comment triggers and reusable-workflow jobs in any PR-capable workflow.
#
# Decision per PR (state is derived from GitHub, nothing is stored here):
#   - skip drafts and locked PRs
#   - skip when title/body/latest commit contains "skip review" / "skip cr"
#   - AUTO:    review when no review by $REVIEWER_LOGIN exists for the current head SHA
#   - MENTION: review when a non-bot OWNER/MEMBER/COLLABORATOR comment containing the
#              mention string is newer than the latest review by $REVIEWER_LOGIN
#   - a review always posts against the current head, so one head is reviewed at most once
#     per mention/push; "auto": false in review-config.json makes it mention-only.
#
# Required environment:
#   GH_TOKEN        token with pull-requests:write + contents:read on every polled repo
#   CHAT_TOKEN      DeepSeek API key
#   REVIEWER_LOGIN  the login that GH_TOKEN authenticates as (used for de-duplication)
#   REVIEW_TOOL_DIR checkout of hustcer/deepseek-review at the pinned commit
#   CONFIG_FILE     path to review-config.json
# Optional:
#   ONLY_REPO / ONLY_PR  restrict to one repo / one PR (workflow_dispatch)
#   FORCE=true           review even if this head already has a review
set -euo pipefail

: "${GH_TOKEN:?}" "${CHAT_TOKEN:?}" "${REVIEWER_LOGIN:?}" "${REVIEW_TOOL_DIR:?}" "${CONFIG_FILE:?}"
export GH_TOKEN

api() { gh api -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }

cfg="$(jq -c . "$CONFIG_FILE")"
enabled="$(jq -r 'if .enabled == false then "false" else "true" end' <<<"$cfg")"
auto="$(jq -r 'if .auto == false then "false" else "true" end' <<<"$cfg")"
mention="$(jq -r '.poll.mention // "@deepseek"' <<<"$cfg")"
max_per_run="$(jq -r '.poll["max-per-run"] // 5' <<<"$cfg")"
model="$(jq -r '.poll.model // "deepseek-v4-flash"' <<<"$cfg")"
exclude="$(jq -r '.poll["exclude-patterns"] // "pnpm-lock.yaml,package-lock.json,*.lock,dist/**,build/**,*.min.js,*.map,vendor/**"' <<<"$cfg")"
mapfile -t repos < <(jq -r '.poll.repos // [] | .[]' <<<"$cfg")

echo "central config: enabled=$enabled auto=$auto mention='$mention' max-per-run=$max_per_run repos=${#repos[@]}"
if [[ "$enabled" != "true" ]]; then echo "reviews are on hold (enabled=false) — nothing to do"; exit 0; fi
if [[ -n "${ONLY_REPO:-}" ]]; then repos=("$ONLY_REPO"); fi
if (( ${#repos[@]} == 0 )); then echo "no repositories configured under poll.repos"; exit 0; fi

reviewed=0
review_pr() {
  local repo="$1" pr="$2" reason="$3"
  echo "::group::review $repo#$pr ($reason)"
  (
    cd "$REVIEW_TOOL_DIR"
    # Mirrors the action.yaml invocation at the pinned commit; GITHUB_ACTIONS=true makes the
    # tool post a COMMENT review to the PR instead of printing to stdout.
    REPO_INPUT="$repo" PR_NUMBER_INPUT="$pr" MODEL_INPUT="$model" EXCLUDE_INPUT="$exclude" \
    nu -I "$REVIEW_TOOL_DIR/nu" -c '
      use review.nu *
      (deepseek-review $env.CHAT_TOKEN
        --model $env.MODEL_INPUT
        --repo $env.REPO_INPUT
        --pr-number $env.PR_NUMBER_INPUT
        --gh-token $env.GH_TOKEN
        --exclude $env.EXCLUDE_INPUT
        --max-length 0)
    '
  )
  echo "::endgroup::"
}

for repo in "${repos[@]}"; do
  echo "== $repo =="
  # A fine-grained PAT answers 404 (not 403) for a repository outside its scope.
  if ! perms="$(api "repos/$repo" --jq '.permissions // {}' 2>/dev/null)"; then
    echo "::error::$repo is not visible to REVIEW_POLL_TOKEN (HTTP 404). Edit the token: Repository access -> Only select repositories -> add $repo; Pull requests = Read and write, Contents = Read."
    exit 1
  fi
  if [[ "$(jq -r '.push // false' <<<"$perms")" != "true" ]]; then
    echo "::error::REVIEW_POLL_TOKEN can read $repo but cannot write pull requests (permissions: $perms). Set Pull requests = Read and write on the token."
    exit 1
  fi
  if [[ -n "${ONLY_PR:-}" ]]; then
    prs="$(api "repos/$repo/pulls/$ONLY_PR" | jq -c '[.]')"
  else
    prs="$(api "repos/$repo/pulls?state=open&per_page=50" | jq -c .)"
  fi
  for row in $(jq -r '.[] | @base64' <<<"$prs"); do
    pr_json="$(base64 -d <<<"$row")"
    pr="$(jq -r .number <<<"$pr_json")"
    head="$(jq -r .head.sha <<<"$pr_json")"
    if [[ "$(jq -r .draft <<<"$pr_json")" == "true" ]]; then echo "#$pr: draft — skip"; continue; fi
    if [[ "$(jq -r .locked <<<"$pr_json")" == "true" ]]; then echo "#$pr: locked — skip"; continue; fi
    if jq -e '((.title // "") + " " + (.body // "")) | ascii_downcase | test("skip review|skip cr")' <<<"$pr_json" >/dev/null; then
      echo "#$pr: skip keyword in title/body — skip"; continue
    fi

    # Latest review by the poller identity, and whether this head already has one.
    reviews="$(api "repos/$repo/pulls/$pr/reviews?per_page=100" | jq -c --arg u "$REVIEWER_LOGIN" '[.[] | select(.user.login == $u)]')"
    last_review_at="$(jq -r 'map(.submitted_at) | max // ""' <<<"$reviews")"
    head_reviewed="$(jq -r --arg h "$head" 'any(.[]; .commit_id == $h)' <<<"$reviews")"

    # Newest qualifying mention comment (non-bot, write access, contains the mention string).
    last_mention_at="$(api "repos/$repo/issues/$pr/comments?per_page=100" | jq -r --arg m "$mention" '
      [ .[] | select(.user.type != "Bot")
            | select(.user.login | endswith("[bot]") | not)
            | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR"))
            | select(.body | test("(^|[^A-Za-z0-9_-])" + ($m | gsub("[.*+?^${}()|\\[\\]\\\\]"; "\\\\" + .)) + "([^A-Za-z0-9_-]|$)")) ]
      | map(.created_at) | max // ""')"

    reason=""
    if [[ "${FORCE:-false}" == "true" ]]; then
      reason="forced"
    elif [[ -n "$last_mention_at" && ( -z "$last_review_at" || "$last_mention_at" > "$last_review_at" ) ]]; then
      reason="mention at $last_mention_at"
    elif [[ "$auto" == "true" && "$head_reviewed" != "true" ]]; then
      reason="new head ${head:0:8}"
    fi

    if [[ -z "$reason" ]]; then echo "#$pr: up to date (head ${head:0:8} reviewed=$head_reviewed, auto=$auto)"; continue; fi
    if (( reviewed >= max_per_run )); then echo "#$pr: due ($reason) but max-per-run=$max_per_run reached — next run"; continue; fi
    review_pr "$repo" "$pr" "$reason"
    reviewed=$((reviewed + 1))
  done
done
echo "done: $reviewed review(s) posted"
