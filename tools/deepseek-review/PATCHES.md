# Vendored review tool — DeepSeek_Sherlock

Source: [hustcer/deepseek-review](https://github.com/hustcer/deepseek-review) **v1.21**,
commit `eccde2e9781008d795e366b951e313e37af88dd5`, MIT licence (`LICENSE`, unchanged).
Vendored files: `nu/common.nu`, `nu/diff.nu`, `nu/review.nu`, `nu/util.nu` (the four the review
path imports; `config.nu` and `release.nu` are not used and were left out).

Every change from upstream is listed here and marked `Sherlock patch Pn` in the code.

| # | File / function | Change | Why |
|---|---|---|---|
| P1 | `diff.nu` `apply-file-filters` → new `run-awk-filter` | Diff is written to a temp file; awk runs on the file and its output is read with `do { … } \| complete` instead of `$content \| try { ^awk … }`. Non-zero exit → the existing "outdated awk" path. | Capturing an external command's output inside `try` deadlocks in Nushell 0.114–0.116 once it exceeds the ~64 KB pipe buffer; reviews of large PRs hung until the job timeout (Project-Aegis #844–#847, waypoint-pm #120). Reproduced locally; output verified byte-identical to plain awk. |
| P2 | `review.nu` `DEFAULT_OPTIONS`, new `SHERLOCK` constant, payload | Default model `deepseek-flash` (was the legacy alias `deepseek-v4-flash`). Payload sends `thinking: {type: enabled}` and `reasoning_effort: max`; `temperature` is omitted (not honoured in thinking mode). | Owner request 2026-10-18: correct model id, thinking on at max. |
| P3 | `review.nu` response handling, new `sherlock-sign` | Reasoning (`reasoning_content`) is never posted to the PR; it is printed to the job log only when `SHERLOCK_LOG_REASONING=true` (the reusable workflow sets it; the public poller does not). Every review ends with a signature line naming DeepSeek_Sherlock, the model id and label, the reasoning effort and the ci-workflows commit (`SHERLOCK_SOURCE_SHA`). `finish_reason=length` with empty content posts a short explanatory review instead of failing silently. | Owner request: name the model in the PR comment. Reasoning can be tens of KB and quotes the diff. |
| P4 | `review.nu` `sherlock-sign` | Review body capped at 65,000 graphemes (GitHub limit 65,536) with a grapheme-safe cut and a `… [truncated: N chars omitted]` marker; the signature always lands last. | Avoid HTTP 422 on very long reviews. |
| P5 | `review.nu`, `diff.nu` HTTP calls | `--max-time`: 600 s on the DeepSeek call, 60 s on GitHub calls. DeepSeek non-2xx responses print status + body and exit non-zero (`-f`); a timeout prints "timed out after …". | A stalled connection now fails in minutes instead of at the job timeout; bad-model / bad-parameter errors are visible. |

## Verification (2026-10-18, before release)

- P1: 508 KB diff with the full exclude list — completes in 0.13 s on Nushell 0.114.1 and 0.116.1, lockfile hunks removed; 20 KB diff output byte-identical (sha256) to plain `awk`. Upstream form hangs on the same input.
- P2/P3: local run against a mock DeepSeek server — request body `model=deepseek-flash`, `thinking.type=enabled`, `reasoning_effort=max`, no `temperature`; review ends with the signature; reasoning absent from the review, present in the log only with `SHERLOCK_LOG_REASONING=true`.
- P4: 100 KB review → 64,952 graphemes, marker present, signature last, no U+FFFD.
- P5: mock HTTP 400 prints the error JSON and exits non-zero; mock stall with a 5 s limit fails at 5.3 s.
- Reusable-workflow gating (ported from upstream `action.yaml`): PR event, owner mention → review; bot, outsider, look-alike mention, no mention, non-PR issue → skip.

## Updating from upstream

Diff upstream `nu/` against the commit above, re-apply P1–P5, re-run the checks, then release
(README, "Releasing a tool change").
