<#
.SYNOPSIS
  Syncs files changed vs `master` from a Windows-side git repo into the matching
  path inside a WSL2 distro, then optionally watches for further changes.

.PARAMETER RepoPath
  Path to the repo on the Windows side, e.g. C:\Users\you\projects\myapp

.PARAMETER WslDistro
  Name of the WSL2 distro, e.g. Ubuntu-22.04 (run `wsl -l -v` to check)

.PARAMETER WslRepoPath
  Absolute path to the repo INSIDE WSL, e.g. /home/you/myapp

.PARAMETER Watch
  If set, after the initial sync it keeps running and mirrors live changes.

.PARAMETER BaseBranch
  Branch to diff against. Defaults to 'master'.

.PARAMETER PollMs
  How often to poll for changes in watch mode. Defaults to 1000ms.

.EXAMPLE
  .\Sync-GitChanges.ps1 -RepoPath C:\dev\myapp -WslDistro Ubuntu-22.04 `
    -WslRepoPath /home/me/myapp -Watch
#>

param(
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [Parameter(Mandatory = $true)][string]$WslDistro,
    [Parameter(Mandatory = $true)][string]$WslRepoPath,
    [switch]$Watch,
    [string]$BaseBranch = "master",
    [int]$PollMs = 1000
)

$ErrorActionPreference = "Stop"

# --- Resolve paths -------------------------------------------------------

$RepoPath = (Resolve-Path $RepoPath).Path.TrimEnd('\')
$RepoName = Split-Path $RepoPath -Leaf
$WslDestRoot = "\\wsl$\$WslDistro$WslRepoPath"

if (-not (Test-Path -LiteralPath $WslDestRoot)) {
    Write-Host "WSL destination not reachable at $WslDestRoot" -ForegroundColor Red
    Write-Host "Check distro name (wsl -l -v) and that the path exists in WSL." -ForegroundColor Yellow
    exit 1
}

# --- Helper: get changed files from git ----------------------------------

function Get-GitChangedFiles {
    param([string]$Base)

    Push-Location $RepoPath
    try {
        $gitArgs = @('-c', 'core.quotepath=false', '-c', 'core.safecrlf=false')

        $committed = (git @gitArgs diff --name-only --diff-filter=ACMRT "$Base...HEAD" 2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }
        $staged    = (git @gitArgs diff --name-only --diff-filter=ACMRT --cached       2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }
        $unstaged  = (git @gitArgs diff --name-only --diff-filter=ACMRT               2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }
        $untracked = (git @gitArgs ls-files --others --exclude-standard               2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }

        $deletedCommitted = (git @gitArgs diff --name-only --diff-filter=D "$Base...HEAD" 2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }
        $deletedWorking   = (git @gitArgs diff --name-only --diff-filter=D               2>&1) | Where-Object { $_ -is [string] -and $_ -notmatch '^warning:' }

        $clean = {
            param($lines)
            $lines | Where-Object { $_ } | ForEach-Object { $_.Trim('"') }
        }

        $changed = @(
            (& $clean $committed),
            (& $clean $staged),
            (& $clean $unstaged),
            (& $clean $untracked)
        ) | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -Unique

        $deleted = @(
            (& $clean $deletedCommitted),
            (& $clean $deletedWorking)
        ) | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -Unique

        return @{
            Changed = [string[]]@($changed)
            Deleted = [string[]]@($deleted)
        }
    }
    finally {
        Pop-Location
    }
}

# --- Helper: snapshot of file -> LastWriteTimeUtc for all tracked files --
# Detects edits by timestamp so a re-save of an already-tracked file
# triggers a sync even though the filename list hasn't changed.

function Get-TimestampSnapshot {
    param([string[]]$Files)

    $snap = @{}
    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        if ($f -match '[<>:"|?*\x00-\x1f]') { continue }
        $src = Join-Path $RepoPath $f
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $snap[$f] = (Get-Item -LiteralPath $src).LastWriteTimeUtc.Ticks
        }
    }
    return $snap
}

# --- Helper: copy one file from Windows repo to WSL ----------------------

function Sync-OneFile {
    param([string]$RelativePath)

    if (-not $RelativePath) { return }

    if ($RelativePath -match '[<>:"|?*\x00-\x1f]') {
        Write-Host "  Skipping unsupported path: $RelativePath" -ForegroundColor Yellow
        return
    }

    $src = Join-Path $RepoPath $RelativePath
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return }

    $dst = Join-Path $WslDestRoot $RelativePath
    $dstDir = Split-Path $dst -Parent

    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $src -Destination $dst -Force
}

# --- Helper: remove one file from WSL ------------------------------------

function Remove-OneFile {
    param([string]$RelativePath)

    if (-not $RelativePath) { return }

    $dst = Join-Path $WslDestRoot $RelativePath
    if (Test-Path -LiteralPath $dst) {
        Remove-Item -LiteralPath $dst -Force
    }
}

# --- Core sync pass -------------------------------------------------------

# --- Core sync pass -------------------------------------------------------

function Invoke-SyncPass {
    param([string]$Base)

    $result = Get-GitChangedFiles -Base $Base
    $count = 0
    $synced = @()

    foreach ($f in @($result.Changed)) {
        Sync-OneFile -RelativePath $f
        $synced += $f
        $count++
    }
    foreach ($f in @($result.Deleted)) {
        Remove-OneFile -RelativePath $f
    }

    if ($count -gt 0 -or $result.Deleted.Count -gt 0) {
        $stamp = Get-Date -Format "HH:mm:ss"
        Write-Host "[$stamp] synced $count file(s), removed $($result.Deleted.Count)" -ForegroundColor Green
        foreach ($f in $synced)          { Write-Host "  + $f" -ForegroundColor DarkGreen }
        foreach ($f in @($result.Deleted)) { Write-Host "  - $f" -ForegroundColor DarkRed }
    }

    return $result
}

# --- Initial full sync ---------------------------------------------------

Write-Host "Initial sync vs '$BaseBranch'..." -ForegroundColor Cyan
$initial = Invoke-SyncPass -Base $BaseBranch
Write-Host "Done. $($initial.Changed.Count) file(s) tracked." -ForegroundColor Cyan

if (-not $Watch) { exit 0 }

# --- Watch mode ----------------------------------------------------------

$lastTimestamps = Get-TimestampSnapshot -Files @($initial.Changed)
$lastFileList   = @(@($initial.Changed) + @($initial.Deleted) | Sort-Object)

$pollCount    = 0
$pollsPer3Sec = [math]::Max(1, [math]::Round(3000 / $PollMs))

Write-Host "  Watching '$RepoName' for changes every ${PollMs}ms (Ctrl+C to stop)..." -ForegroundColor DarkCyan
Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
			
try {
    while ($true) {
        Start-Sleep -Milliseconds $PollMs
        $pollCount++

        $result            = Get-GitChangedFiles -Base $BaseBranch
        $currentFileList   = @(@($result.Changed) + @($result.Deleted) | Sort-Object)
        $currentTimestamps = Get-TimestampSnapshot -Files @($result.Changed)

        $fileListChanged = (Compare-Object -ReferenceObject $lastFileList -DifferenceObject $currentFileList) -ne $null

        $contentChanged = $false
        foreach ($f in @($result.Changed)) {
            if (-not $f) { continue }
            if ($currentTimestamps[$f] -ne $lastTimestamps[$f]) {
                $contentChanged = $true
                break
            }
        }

        if ($fileListChanged -or $contentChanged) {
            $prevFileList   = $lastFileList
            $prevTimestamps = $lastTimestamps

            $lastFileList   = $currentFileList
            $lastTimestamps = $currentTimestamps

            $count = 0
            $syncedFiles  = @()
            $deletedFiles = @()

            foreach ($f in @($result.Changed)) {
                $isNew      = $prevFileList -notcontains $f
                $isModified = $currentTimestamps[$f] -ne $prevTimestamps[$f]
                if ($isNew -or $isModified) { $syncedFiles += $f }
                Sync-OneFile -RelativePath $f
                $count++
            }
            foreach ($f in @($result.Deleted)) {
                Remove-OneFile -RelativePath $f
                $deletedFiles += $f
            }

            $stamp = Get-Date -Format "HH:mm:ss"
            Write-Host "  [$stamp] change detected" -ForegroundColor Cyan
            foreach ($f in $syncedFiles)  { Write-Host "    + $f" -ForegroundColor Green }
            foreach ($f in $deletedFiles) { Write-Host "    - $f" -ForegroundColor Red }
            Write-Host "  $count file(s) synced, $($deletedFiles.Count) removed" -ForegroundColor DarkCyan
            Write-Host ""

            # Reset counter so the clear doesn't immediately wipe a fresh change
            $pollCount = 0
        }

        if ($pollCount -ge $pollsPer3Sec) {
            $pollCount = 0
            Clear-Host
			Write-Host "  Watching '$RepoName' for changes every ${PollMs}ms (Ctrl+C to stop)..." -ForegroundColor DarkCyan
			Write-Host "  --------------------------------------------------------" -ForegroundColor DarkGray
			Write-Host "  Tracking $($lastFileList.Count) file(s) vs '$BaseBranch'" -ForegroundColor DarkGray
			Write-Host ""
        }
    }
}
finally {
    Write-Host "  Watcher stopped." -ForegroundColor Yellow
}
