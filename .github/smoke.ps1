<#
.SYNOPSIS
    Behaviour tests for connect.ps1 that need no Backblaze account.

.DESCRIPTION
    Mirrors .github/smoke.sh. Everything here either fails before touching the
    network, or fails against B2's auth endpoint with deliberately wrong
    credentials. The one test that does reach out asserts only "non-zero exit and
    no remote left behind", which holds whether the request 401s or cannot
    connect at all.

.EXAMPLE
    $env:RCLONE_CONFIG = "$env:TEMP\scratch.conf"
    .\smoke.ps1 -Script ..\connect.ps1
#>

param(
    [string] $Script = './connect.ps1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $env:RCLONE_CONFIG) {
    throw 'set $env:RCLONE_CONFIG to a scratch path so the real config is safe'
}
Remove-Item -LiteralPath $env:RCLONE_CONFIG -Force -ErrorAction SilentlyContinue
New-Item -ItemType File -Path $env:RCLONE_CONFIG -Force | Out-Null

# These MUST be cleared. If the calling environment happens to have real
# credentials in it, every "refuses without credentials" test below would pass
# for entirely the wrong reason -- the script would sail past the prompt and fail
# later at authentication instead.
$env:B2_KEY_ID = $null
$env:B2_APP_KEY = $null

$script:Pass = 0
$script:Fail = 0

function Pass { param([string]$Label) $script:Pass++; Write-Host "ok    $Label" }
function Fail {
    param([string]$Label, [string]$Detail)
    $script:Fail++
    Write-Host "FAIL  $Label"
    if ($Detail) { ($Detail -split "`r?`n") | ForEach-Object { Write-Host "        $_" } }
}

# connect.ps1 calls exit, so it has to run in a child process or it would take
# this test runner down with it. Reuse whichever PowerShell is hosting us so
# 5.1 is exercised under 5.1 and 7 under 7.
$PsExe = (Get-Process -Id $PID).Path

function Invoke-Target {
    param([string[]] $Arguments, [hashtable] $WithEnv)

    $saved = @{}
    if ($WithEnv) {
        foreach ($k in $WithEnv.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, $WithEnv[$k])
        }
    }
    try {
        # 'Continue' so that native stderr does not become a terminating
        # NativeCommandError under Windows PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        $out = & $PsExe -NoProfile -File $Script @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    }
    finally {
        foreach ($k in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($k, $saved[$k])
        }
    }
}

function Expect-Exit {
    param([int] $Want, [string] $Label, [string[]] $Arguments, [hashtable] $WithEnv)
    $r = Invoke-Target -Arguments $Arguments -WithEnv $WithEnv
    if ($r.Code -eq $Want) { Pass "$Label (exit $($r.Code))" }
    else { Fail "$Label (wanted exit $Want, got $($r.Code))" $r.Output }
}

function Expect-Output {
    param([string] $Label, [string] $Needle, [string[]] $Arguments, [hashtable] $WithEnv)
    $r = Invoke-Target -Arguments $Arguments -WithEnv $WithEnv
    if ($r.Output -like "*$Needle*") { Pass $Label }
    else { Fail "$Label (no '$Needle' in output)" $r.Output }
}

function Get-Remotes {
    $ErrorActionPreference = 'Continue'
    $out = & rclone listremotes 2>&1 | Out-String
    return (($out -split "`r?`n") | Where-Object { $_.Trim() }) -join ' '
}

Write-Host "--- connect.ps1 behaviour (PowerShell $($PSVersionTable.PSVersion)) ---"

# --- argument validation, no credentials needed ---------------------------
Expect-Exit   1 "remote name with ':' rejected"  @('-Remote', 'has:colon')
Expect-Exit   1 "remote name with '/' rejected"  @('-Remote', 'has/slash')
Expect-Exit   1 "remote name with '\' rejected"  @('-Remote', 'has\back')
Expect-Exit   1 'empty remote name rejected'     @('-Remote', '')
Expect-Output 'rejection names the bad character' 'cannot contain' @('-Remote', 'has:colon')

# --- missing credentials, with stdin redirected ---------------------------
# The assertion is on the message, not just the exit code: exiting 1 for some
# unrelated reason would otherwise look like a pass.
Expect-Exit   1 'refuses without a keyID when non-interactive' @('-Remote', 't1', '-Yes')
Expect-Output 'says how to supply a keyID' 'B2_KEY_ID' @('-Remote', 't1', '-Yes')
Expect-Output 'refuses without an applicationKey' 'B2_APP_KEY' `
    @('-Remote', 't2', '-Yes') @{ B2_KEY_ID = '005hasidbutnokey00000000' }

# --- rollback: a remote that fails verification must not survive ----------
$before = Get-Remotes
$r = Invoke-Target -Arguments @('-Remote', 'rollbackme', '-Yes') -WithEnv @{
    B2_KEY_ID  = '005deadbeefdeadbeef000000'
    B2_APP_KEY = 'K005notARealApplicationKeyAtAll'
}
$after = Get-Remotes

if ($r.Code -ne 0) { Pass "bad credentials fail (exit $($r.Code))" }
else { Fail 'bad credentials fail' $r.Output }

if ($after -notlike '*rollbackme*') {
    Pass "broken remote rolled back (remotes: $(if ($after) { $after } else { 'none' }))"
}
else { Fail 'broken remote rolled back' "still present: $after" }

if ($before -eq $after) { Pass 'config unchanged overall' }
else { Fail 'config unchanged overall' "before: [$before] after: [$after]" }

# --- an existing remote is never clobbered without consent ----------------
$ErrorActionPreference = 'Continue'
& rclone config create keepme b2 account sentinel-account key sentinel-key 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'

$r = Invoke-Target -Arguments @('-Remote', 'keepme')
$shown = & rclone config show keepme 2>&1 | Out-String
$sentinel = (($shown -split "`r?`n") |
    Where-Object { $_ -match '^account\s*=' } |
    ForEach-Object { ($_ -split '=', 2)[1].Trim() } | Select-Object -First 1)

if ($r.Code -eq 1 -and $sentinel -eq 'sentinel-account') {
    Pass 'existing remote left intact without -Force'
}
else { Fail 'existing remote left intact without -Force' "exit $($r.Code), account now '$sentinel'" }

# --- probe hygiene --------------------------------------------------------
# Asserted by reading the script rather than by round-tripping to B2, since
# there are no credentials here. A soft delete would leave a permanent hidden
# version in the user's bucket, so this must not regress.
if ((Get-Content -Raw -LiteralPath $Script) -match "deletefile', '--b2-hard-delete") {
    Pass 'probe object is hard-deleted'
}
else { Fail 'probe object is hard-deleted' "no hard-delete of the probe found in $Script" }

Remove-Item -LiteralPath $env:RCLONE_CONFIG -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "--- $script:Pass passed, $script:Fail failed ---"
if ($script:Fail -gt 0) { exit 1 }
