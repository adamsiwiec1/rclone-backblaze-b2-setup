<#
.SYNOPSIS
    Configure an rclone remote for Backblaze B2 and prove it works.

.DESCRIPTION
    Does three things and stops:
      1. checks rclone is installed, and offers to install it if not
      2. writes a B2 remote into your rclone config
      3. verifies the credentials actually work, including write access

    If verification fails on a remote this script just created, the remote is
    removed again rather than left behind broken.

    This is the Windows counterpart of connect.sh and behaves the same way.
    Runs on Windows PowerShell 5.1 (which ships with Windows 10 and 11) and on
    PowerShell 7 anywhere.

.PARAMETER Remote
    Name for the rclone remote. Default: b2

.PARAMETER KeyId
    B2 application keyID. Falls back to $env:B2_KEY_ID, then prompts.

.PARAMETER AppKey
    B2 applicationKey. Falls back to $env:B2_APP_KEY, then prompts without echo.

.PARAMETER Bucket
    Bucket to verify read/write against. Strongly recommended: without it only
    listing can be checked.

.PARAMETER CreateBucket
    Create the bucket if it does not exist.

.PARAMETER Force
    Replace an existing remote of the same name without asking.

.PARAMETER NoInstall
    Fail instead of offering to install rclone.

.PARAMETER Yes
    Assume yes to prompts, for scripted use.

.EXAMPLE
    .\connect.ps1

.EXAMPLE
    .\connect.ps1 -Bucket my-backup-bucket

.EXAMPLE
    .\connect.ps1 -Remote b2prod -Bucket my-backup-bucket -CreateBucket

.LINK
    https://secure.backblaze.com/app_keys.htm
#>

param(
    [string] $Remote = 'b2',
    [string] $KeyId,
    [string] $AppKey,
    [string] $Bucket,
    [switch] $CreateBucket,
    [switch] $Force,
    [switch] $NoInstall,
    [switch] $Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host ''; Write-Host '==> ' -ForegroundColor White -NoNewline; Write-Host $Message }
function Write-Ok   { param([string]$Message) Write-Host '    ok    ' -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn { param([string]$Message) Write-Host '    warn  ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Plain { param([string]$Message = '') Write-Host $Message }

function Exit-WithError {
    param([string]$Message)
    Write-Host ''
    Write-Host 'error ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

function Confirm-Action {
    param([string]$Question)
    if ($Yes) { return $true }
    # A redirected or absent stdin cannot answer, so do not hang waiting.
    if ([Console]::IsInputRedirected) {
        Write-Warn 'input is redirected and -Yes not given, assuming no'
        return $false
    }
    $reply = Read-Host "    $Question [y/N]"
    return ($reply -match '^(y|yes)$')
}

# Runs rclone and hands back the exit code plus combined output.
#
# $ErrorActionPreference is deliberately dropped to Continue inside this
# function. Windows PowerShell 5.1 turns a native command's stderr into error
# records, and under 'Stop' the 2>&1 below would throw NativeCommandError the
# moment rclone printed a warning -- which it does routinely. The assignment is
# function-scoped, so the caller keeps 'Stop'.
function Invoke-Rclone {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    $output = & rclone @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
        Code    = $LASTEXITCODE
        Output  = $output
        Success = ($LASTEXITCODE -eq 0)
    }
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

if (-not $Remote) { Exit-WithError '-Remote cannot be empty' }
if ($Remote -match '[:/\\]') { Exit-WithError "remote name cannot contain ':', '/' or '\': $Remote" }

Write-Host "rclone + Backblaze B2 setup (connect.ps1 $ScriptVersion)"

# --------------------------------------------------------------------------
# 1. rclone
# --------------------------------------------------------------------------
Write-Step 'checking for rclone'

function Get-InstallCommand {
    if (Test-Command 'winget') { return @{ Label = 'winget install Rclone.Rclone'; Exe = 'winget'; Args = @('install', '--id', 'Rclone.Rclone', '-e', '--source', 'winget') } }
    if (Test-Command 'scoop')  { return @{ Label = 'scoop install rclone';         Exe = 'scoop';  Args = @('install', 'rclone') } }
    if (Test-Command 'choco')  { return @{ Label = 'choco install rclone -y';      Exe = 'choco';  Args = @('install', 'rclone', '-y') } }
    return $null
}

if (Test-Command 'rclone') {
    $ver = (Invoke-Rclone @('version')).Output -split "`n" | Select-Object -First 1
    Write-Ok "$($ver.Trim()) found at $((Get-Command rclone).Source)"
}
else {
    Write-Warn 'rclone is not installed'
    $installer = Get-InstallCommand

    if ($NoInstall -or -not $installer) {
        Write-Plain ''
        Write-Plain '  Install it with one of:'
        Write-Plain '    winget install Rclone.Rclone'
        Write-Plain '    scoop install rclone'
        Write-Plain '    choco install rclone -y'
        Write-Plain ''
        Write-Info 'Or download the zip from https://rclone.org/downloads/ and put'
        Write-Info 'rclone.exe somewhere on your PATH.'
        Exit-WithError 'rclone is required'
    }

    Write-Plain ''
    Write-Plain '  Suggested install command for this machine:'
    Write-Plain "    $($installer.Label)"
    Write-Plain ''
    if (-not (Confirm-Action 'Run that now?')) {
        Exit-WithError 'rclone is required. Install it and re-run.'
    }

    & $installer.Exe @($installer.Args)

    # A fresh install lands in a directory this process may not have on PATH
    # yet, so refresh from the registry before giving up. $env:OS is used rather
    # than $IsWindows because $IsWindows does not exist in Windows PowerShell
    # 5.1, and Set-StrictMode makes reading an undefined variable an error.
    if (-not (Test-Command 'rclone') -and $env:OS -eq 'Windows_NT') {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Test-Command 'rclone')) {
        Exit-WithError 'rclone installed but is not on PATH yet. Open a new terminal and re-run.'
    }
    Write-Ok 'rclone installed'
}

$configPath = ((Invoke-Rclone @('config', 'file')).Output -split "`n" |
    Where-Object { $_.Trim() } | Select-Object -Last 1)
if ($configPath) { $configPath = $configPath.Trim(); Write-Info "config: $configPath" }

# --------------------------------------------------------------------------
# 2. credentials
# --------------------------------------------------------------------------
Write-Step 'credentials'

$remoteExisted = $false
$listed = (Invoke-Rclone @('listremotes')).Output -split "`r?`n" | ForEach-Object { $_.Trim() }
if ($listed -contains "${Remote}:") {
    $remoteExisted = $true
    $existingType = ((Invoke-Rclone @('config', 'show', $Remote)).Output -split "`r?`n" |
        Where-Object { $_ -match '^type\s*=' } |
        ForEach-Object { ($_ -split '=', 2)[1].Trim() } | Select-Object -First 1)
    if (-not $existingType) { $existingType = 'unknown' }

    if ($Force) {
        Write-Warn "remote '$Remote' already exists (type $existingType), replacing it"
    }
    else {
        Write-Plain ''
        Write-Plain "  A remote called '$Remote' already exists (type $existingType)."
        Write-Plain '  Re-running will overwrite its keys.'
        Write-Plain ''
        if (-not (Confirm-Action 'Overwrite it?')) {
            Exit-WithError "nothing changed. Use -Remote NAME to set up a different one."
        }
    }
}

if (-not $KeyId) { $KeyId = $env:B2_KEY_ID }
if (-not $KeyId) {
    if ([Console]::IsInputRedirected) {
        Exit-WithError 'no keyID given. Pass -KeyId, set $env:B2_KEY_ID, or run interactively.'
    }
    Write-Plain ''
    Write-Info 'Create an application key at https://secure.backblaze.com/app_keys.htm'
    Write-Info 'Scope it to one bucket. Do not use the master key.'
    Write-Plain ''
    $KeyId = Read-Host '    keyID'
}
if (-not $KeyId) { Exit-WithError 'keyID cannot be empty' }

if (-not $AppKey) { $AppKey = $env:B2_APP_KEY }
if (-not $AppKey) {
    if ([Console]::IsInputRedirected) {
        Exit-WithError 'no applicationKey given. Pass -AppKey, set $env:B2_APP_KEY, or run interactively.'
    }
    # -AsSecureString keeps the key out of the console scrollback. It has to be
    # unprotected again below because rclone takes it as a plain argument; there
    # is no way to hand rclone a SecureString.
    $secure = Read-Host '    applicationKey (not echoed)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { $AppKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $AppKey) { Exit-WithError 'applicationKey cannot be empty' }

# Backblaze shows the keyID and applicationKey next to each other and they are
# easy to paste the wrong way round. The keyID is short and hex; the
# applicationKey is longer and starts with K.
if ($KeyId -like 'K0*' -and $KeyId.Length -gt 26) {
    Write-Warn 'that keyID looks like an applicationKey -- are they swapped?'
}

# --------------------------------------------------------------------------
# 3. write the remote
# --------------------------------------------------------------------------
Write-Step "writing remote '$Remote'"

# hard_delete stays at its default of false on purpose. With it false, deleting
# a file on B2 hides it and a lifecycle rule can remove it later, which leaves
# you an undelete window. See the README.
$created = Invoke-Rclone @('config', 'create', $Remote, 'b2', 'account', $KeyId, 'key', $AppKey)
if (-not $created.Success) {
    Exit-WithError "rclone config create failed for remote '$Remote'`n$($created.Output)"
}
$where = if ($configPath) { $configPath } else { 'the rclone config' }
Write-Ok "remote '$Remote' written to $where"

function Undo-Remote {
    if (-not $remoteExisted) {
        Invoke-Rclone @('config', 'delete', $Remote) | Out-Null
        Write-Info "removed remote '$Remote' again, since setup did not finish"
    }
    else {
        Write-Warn "remote '$Remote' was overwritten with keys that did not verify"
    }
}

# --------------------------------------------------------------------------
# 4. verify
# --------------------------------------------------------------------------
Write-Step 'verifying'

# Listing buckets needs the listBuckets capability. A key scoped to a single
# bucket does NOT have it, so this failing is not conclusive -- it is only
# conclusive when no bucket was given and there is nothing else to try.
$listOk = $false
$list = Invoke-Rclone @('lsd', "${Remote}:")
if ($list.Success) {
    $listOk = $true
    $n = (($list.Output -split "`r?`n") | Where-Object { $_.Trim() }).Count
    Write-Ok "authenticated, and the key can list buckets ($n visible)"
}
elseif ($Bucket) {
    Write-Warn 'cannot list all buckets -- normal for a bucket-scoped key'
}
else {
    Write-Plain ''
    ($list.Output -split "`r?`n") | Where-Object { $_.Trim() } | ForEach-Object { Write-Plain "      $_" }
    Write-Plain ''
    Undo-Remote
    Exit-WithError @"
could not authenticate, and no -Bucket was given to test directly.
      If this key is scoped to one bucket, re-run with:
        .\connect.ps1 -Remote $Remote -Bucket YOUR-BUCKET
"@
}

if (-not $Bucket) {
    Write-Warn 'no -Bucket given, so write access was not tested'
    Write-Info 'A key can list buckets and still be unable to write to them.'
}
else {
    if ((Invoke-Rclone @('lsf', "${Remote}:${Bucket}", '--max-depth', '1')).Success) {
        Write-Ok "bucket '$Bucket' is reachable"
    }
    elseif ($CreateBucket) {
        if ((Invoke-Rclone @('mkdir', "${Remote}:${Bucket}")).Success) {
            Write-Ok "bucket '$Bucket' created"
        }
        else {
            Undo-Remote
            Exit-WithError @"
could not create bucket '$Bucket'.
      Bucket names are globally unique across all of Backblaze B2, so a plain
      name like 'backup' is long gone. Try 'yourname-hostname-backup'.
"@
        }
    }
    else {
        Undo-Remote
        Exit-WithError @"
bucket '$Bucket' is not reachable.
      Either it does not exist -- re-run with -CreateBucket -- or this key is
      scoped to a different bucket.
"@
    }

    # Write, read back, delete. This is the only step that proves the key is
    # actually usable for a backup; checks that never write will happily succeed
    # against buckets you cannot touch.
    $probe = ".rclone-b2-setup-probe-{0}-{1}" -f (Get-Date -Format 'yyyyMMddHHmmss'), $PID
    $probeLocal = [System.IO.Path]::GetTempFileName()
    "written by connect.ps1 at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))" |
        Set-Content -LiteralPath $probeLocal -Encoding ASCII

    # --b2-hard-delete is not optional here. A normal delete on B2 only HIDES a
    # file: the version stays in the bucket, stays billable, and stops the
    # bucket from ever being empty. Verifying a connection should not leave a
    # permanent object behind, so the probe -- and only the probe -- really goes.
    $removeProbe = {
        Invoke-Rclone @('deletefile', '--b2-hard-delete', "${Remote}:${Bucket}/${probe}") | Out-Null
        Remove-Item -LiteralPath $probeLocal -Force -ErrorAction SilentlyContinue
    }

    try {
        if (-not (Invoke-Rclone @('copyto', $probeLocal, "${Remote}:${Bucket}/${probe}")).Success) {
            Remove-Item -LiteralPath $probeLocal -Force -ErrorAction SilentlyContinue
            Undo-Remote
            Exit-WithError @"
the key can see bucket '$Bucket' but cannot write to it.
      Application keys can be read-only; check the key's permissions at
      https://secure.backblaze.com/app_keys.htm
"@
        }
        Write-Ok 'wrote a probe object'

        if (-not (Invoke-Rclone @('cat', "${Remote}:${Bucket}/${probe}")).Success) {
            & $removeProbe
            Undo-Remote
            Exit-WithError 'wrote the probe object but could not read it back'
        }
        Write-Ok 'read it back'

        if ((Invoke-Rclone @('deletefile', '--b2-hard-delete', "${Remote}:${Bucket}/${probe}")).Success) {
            Write-Ok 'deleted it, leaving the bucket exactly as it was'
        }
        else {
            Write-Warn "could not delete the probe object ${Bucket}/${probe} -- remove it by hand"
        }
    }
    finally {
        Remove-Item -LiteralPath $probeLocal -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# 5. what to do next
# --------------------------------------------------------------------------
$shown = if ($Bucket) { $Bucket } else { 'YOUR-BUCKET' }
$dest = "${Remote}:${shown}"

Write-Plain ''
Write-Host 'Connected.' -ForegroundColor Green -NoNewline
Write-Host " Remote '$Remote' is configured and working."
Write-Plain ''
Write-Plain '  Try it:'
Write-Plain "    rclone lsd ${Remote}:"
Write-Plain "    rclone ls $dest"
Write-Plain "    rclone copy `$env:USERPROFILE\Documents $dest/Documents"
Write-Plain "    rclone sync `$env:USERPROFILE\Documents $dest/Documents --dry-run"
Write-Plain ''
Write-Plain '  Always --dry-run a sync first. sync makes the destination match the'
Write-Plain '  source, which means it deletes remote files that are gone locally.'
Write-Plain ''
if (-not $listOk) {
    Write-Plain "  Note: this key is scoped to one bucket, so 'rclone lsd ${Remote}:' fails with"
    Write-Plain '  401 unauthorized. That is expected. Always name the bucket instead:'
    Write-Plain "    rclone ls $dest"
    Write-Plain ''
}
Write-Plain '  One thing worth doing now, once per bucket:'
Write-Plain "    rclone backend lifecycle $dest -o daysFromHidingToDeleting=30"
Write-Plain ''
Write-Info 'On B2, deleting a file only hides it -- the bytes stay billable forever'
Write-Info 'unless a lifecycle rule removes them. That command gives you a 30-day'
Write-Info 'undelete window, after which you stop paying. Needs rclone 1.65+.'
Write-Plain ''
