# review.ps1 — operate the DeepSeek PR review workflow across ModernNomad-98 repositories.
#
#   pwsh ./review.ps1 -Action status
#   pwsh ./review.ps1 -Action disable -Repos waypoint-pm,Project-Aegis
#   pwsh ./review.ps1 -Action enable
#
# Central (all-repo) switches are documented in README.md and edited in
# .github/workflows/deepseek-review.yml (`enabled` / `auto` input defaults).
#requires -Version 7
param(
    [Parameter(Mandatory)][ValidateSet('status', 'disable', 'enable')][string]$Action,
    [string[]]$Repos = @('waypoint-pm', 'Project-Aegis', 'opsflow'),
    [string]$Owner = 'ModernNomad-98'
)

$ErrorActionPreference = 'Continue'
$workflowName = 'DeepSeek Code Review'

foreach ($repo in $Repos) {
    $full = "$Owner/$repo"
    Write-Host "== $full"

    $row = gh api "repos/$full/actions/workflows" --jq ".workflows[] | select(.name==\"$workflowName\") | [.id, .state] | @tsv" 2>$null
    if (-not $row) {
        Write-Host "   caller not present on the default branch (not merged yet) — nothing to do"
        continue
    }
    $parts = $row -split "`t"
    $id = $parts[0]
    $state = $parts[1]

    switch ($Action) {
        'status' {
            $secret = gh secret list -R $full 2>$null | Select-String -Pattern '^CHAT_TOKEN\b'
            $var = gh variable list -R $full 2>$null | Select-String -Pattern '^DEEPSEEK_REVIEW_ENABLED\b'
            $secretState = if ($secret) { 'present' } else { 'MISSING' }
            $varState = if ($var) { ($var -split "\s+")[1] } else { '(unset = enabled)' }
            Write-Host "   workflow id=$id state=$state | CHAT_TOKEN=$secretState | DEEPSEEK_REVIEW_ENABLED=$varState"
        }
        'disable' {
            gh workflow disable $id -R $full | Out-Null
            Write-Host '   disabled'
        }
        'enable' {
            gh workflow enable $id -R $full | Out-Null
            Write-Host '   enabled'
        }
    }
}

if ($Action -eq 'status') {
    Write-Host ''
    Write-Host 'Central switches: .github/workflows/deepseek-review.yml (enabled / auto input defaults).'
}
