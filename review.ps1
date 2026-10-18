# review.ps1 — operate the DeepSeek PR review workflow across ModernNomad-98 repositories.
#
#   pwsh ./review.ps1 -Action status
#   pwsh ./review.ps1 -Action hold              # central: every caller stops reviewing
#   pwsh ./review.ps1 -Action resume            # central: reviews re-enabled
#   pwsh ./review.ps1 -Action mention-only      # central: automatic reviews off, @mention still works
#   pwsh ./review.ps1 -Action disable -Repos waypoint-pm,Project-Aegis
#   pwsh ./review.ps1 -Action enable
#requires -Version 7
param(
    [Parameter(Mandatory)][ValidateSet('status', 'hold', 'resume', 'mention-only', 'disable', 'enable')][string]$Action,
    [string[]]$Repos = @('waypoint-pm', 'Project-Aegis', 'opsflow'),
    [string]$Owner = 'ModernNomad-98',
    [string]$ConfigRepo = 'ModernNomad-98/ci-workflows'
)

$ErrorActionPreference = 'Stop'
$workflowName = 'DeepSeek Code Review'

function Get-CentralConfig {
    $raw = gh api -H 'Accept: application/vnd.github.raw' "repos/$ConfigRepo/contents/review-config.json" 2>$null
    if (-not $raw) { throw "cannot read review-config.json from $ConfigRepo" }
    return ($raw | Out-String) | ConvertFrom-Json
}

function Set-CentralConfig([bool]$Enabled, [bool]$Auto, [string]$Message) {
    $cfg = Get-CentralConfig
    $sha = (gh api "repos/$ConfigRepo/contents/review-config.json" --jq '.sha').Trim()
    $cfg.enabled = $Enabled
    $cfg.auto = $Auto
    $json = $cfg | ConvertTo-Json -Depth 5
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    gh api --method PUT "repos/$ConfigRepo/contents/review-config.json" -f message="$Message" -f content="$b64" -f sha="$sha" -f branch='main' | Out-Null
    Write-Host "central config updated ($Message)"
}

switch ($Action) {
    'hold'         { Set-CentralConfig -Enabled $false -Auto $true  -Message 'chore: hold DeepSeek reviews (central switch)'; break }
    'resume'       { Set-CentralConfig -Enabled $true  -Auto $true  -Message 'chore: resume DeepSeek reviews (central switch)'; break }
    'mention-only' { Set-CentralConfig -Enabled $true  -Auto $false -Message 'chore: DeepSeek reviews on mention only (central switch)'; break }
}

$cfg = $null
try { $cfg = Get-CentralConfig } catch { Write-Host "central config: unavailable ($($_.Exception.Message))" }
if ($cfg) { Write-Host "central config: enabled=$($cfg.enabled) auto=$($cfg.auto)" }

foreach ($repo in $Repos) {
    $full = "$Owner/$repo"
    Write-Host "== $full"

    $row = gh api "repos/$full/actions/workflows" --jq ".workflows[] | select(.name==\"$workflowName\") | [.id, .state] | @tsv" 2>$null
    if (-not $row) {
        Write-Host "   caller not present on the default branch (not merged yet) - nothing to do"
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
        'disable' { gh workflow disable $id -R $full | Out-Null; Write-Host '   disabled' }
        'enable'  { gh workflow enable $id -R $full | Out-Null; Write-Host '   enabled' }
    }
}
