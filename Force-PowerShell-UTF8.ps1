# Save as: Force-PowerShell-UTF8.ps1
# Run once in PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\Force-PowerShell-UTF8.ps1

[CmdletBinding()]
param(
    [switch]$ElevatedRelaunch
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsUtf8 {
    try {
        $encodings = @(
            [Console]::InputEncoding.WebName,
            [Console]::OutputEncoding.WebName,
            $OutputEncoding.WebName
        ) | Where-Object { $_ }

        foreach ($name in $encodings) {
            if ($name -notin @('utf-8', 'utf8')) {
                return $false
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Apply-Utf8ToCurrentSession {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [Console]::InputEncoding  = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $global:OutputEncoding    = $utf8NoBom

    # Common file-writing cmdlets default to UTF-8
    $global:PSDefaultParameterValues['Out-File:Encoding']   = 'utf8'
    $global:PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
    $global:PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'
    $global:PSDefaultParameterValues['Export-Csv:Encoding']  = 'utf8'

    # Switch console code page to UTF-8
    & "$env:SystemRoot\System32\chcp.com" 65001 > $null
}

function Set-ManagedBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Block,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $existing = ''
    if (Test-Path $Path) {
        $existing = Get-Content -Path $Path -Raw -ErrorAction Stop
    }

    $managedContent = @"
$StartMarker
$Block
$EndMarker
"@

    $pattern = "(?s)" + [regex]::Escape($StartMarker) + ".*?" + [regex]::Escape($EndMarker)

    if ($existing -match $pattern) {
        $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $managedContent }, 1)
    } else {
        if ([string]::IsNullOrWhiteSpace($existing)) {
            $updated = $managedContent
        } else {
            $updated = $existing.TrimEnd() + "`r`n`r`n" + $managedContent
        }
    }

    Set-Content -Path $Path -Value $updated -Encoding UTF8 -Force
}

# Already UTF-8: nothing to do
if (Test-IsUtf8) {
    Write-Output 'Your powershell is already using utf-8.'
    exit 0
}

# Need elevation to write global/all-users profiles
if (-not (Test-IsAdmin)) {
    if (-not $PSCommandPath) {
        throw 'This script must be saved as a .ps1 file before it can auto-relaunch as administrator.'
    }

    $hostExe = (Get-Process -Id $PID).Path
    if (-not $hostExe) {
        $hostExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-ElevatedRelaunch'
    )

    Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs | Out-Null
    exit 0
}

# UTF-8 bootstrap code to be written into global profiles
$startMarker = '# >>> CHATGPT_FORCE_UTF8_BEGIN >>>'
$endMarker   = '# <<< CHATGPT_FORCE_UTF8_END <<<'

$utf8Block = @'
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [Console]::InputEncoding  = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $global:OutputEncoding    = $utf8NoBom

    $global:PSDefaultParameterValues['Out-File:Encoding']    = 'utf8'
    $global:PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
    $global:PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'
    $global:PSDefaultParameterValues['Export-Csv:Encoding']  = 'utf8'

    & "$env:SystemRoot\System32\chcp.com" 65001 > $null
} catch {
}
'@

# Collect global profile targets:
# 1) Current engine's AllUsersAllHosts profile
# 2) Windows PowerShell 5.1 global profile
# 3) Installed PowerShell 7+ global profiles under Program Files\PowerShell\*\profile.ps1
$targetProfiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

if ($PROFILE -and $PROFILE.AllUsersAllHosts) {
    $null = $targetProfiles.Add($PROFILE.AllUsersAllHosts)
}

$legacyProfile = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'
$null = $targetProfiles.Add($legacyProfile)

$pwshRoot = Join-Path $env:ProgramFiles 'PowerShell'
if (Test-Path $pwshRoot) {
    Get-ChildItem -Path $pwshRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $profilePath = Join-Path $_.FullName 'profile.ps1'
        $null = $targetProfiles.Add($profilePath)
    }
}

foreach ($profilePath in $targetProfiles) {
    Set-ManagedBlock -Path $profilePath -Block $utf8Block -StartMarker $startMarker -EndMarker $endMarker
}

# Apply immediately to current session too
Apply-Utf8ToCurrentSession

if (Test-IsUtf8) {
    Write-Output 'Your powershell has switch to utf-8, enjoy!'
    exit 0
} else {
    throw 'Failed to switch PowerShell to UTF-8.'
}