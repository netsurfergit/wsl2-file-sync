# Sync-GitChanges.ps1

A PowerShell script that syncs git-tracked file changes from a Windows repository into a WSL2 distro in real time. Designed for developers who edit code in a Windows IDE but run and test inside WSL2 as writing large amounts of files between WSL2 & Windows directories is notoriously slow.

## How it works

Instead of syncing the entire repository (which would include `node_modules` and other large ignored directories), the script asks git which files differ from a base branch and only copies those. This means:

- `node_modules`, build output, and anything in `.gitignore` are never touched
- The initial sync is fast even on large monorepos
- Watch mode polls git every second and detects changes by file timestamp, so saving a file in your IDE triggers an immediate copy to WSL2

### What gets synced

| Source | git command used |
|---|---|
| Commits ahead of base branch | `git diff --name-only master...HEAD` |
| Staged changes | `git diff --name-only --cached` |
| Unstaged edits | `git diff --name-only` |
| New untracked files | `git ls-files --others --exclude-standard` |
| Deleted files | `git diff --name-only --diff-filter=D` (removed from WSL) |

## Requirements

- Windows 10/11 with WSL2 installed
- PowerShell 5.1 or later
- Git for Windows (git must be available on `PATH`)
- The target directory must already exist inside WSL2

## Usage

### One-off sync

Syncs all changed files once and exits.

```powershell
.\Sync-GitChanges.ps1 `
  -RepoPath     C:\dev\myapp `
  -WslDistro    Ubuntu-22.04 `
  -WslRepoPath  /home/you/myapp
```

### Watch mode

Syncs on startup, then watches for further changes and mirrors them continuously.

```powershell
.\Sync-GitChanges.ps1 `
  -RepoPath     C:\dev\myapp `
  -WslDistro    Ubuntu-22.04 `
  -WslRepoPath  /home/you/myapp `
  -Watch
```

Press `Ctrl+C` to stop.

### Run in the background (no console window)

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList `
  '-NoExit', '-File', '.\Sync-GitChanges.ps1', `
  '-RepoPath',    'C:\dev\myapp', `
  '-WslDistro',   'Ubuntu-22.04', `
  '-WslRepoPath', '/home/you/myapp', `
  '-Watch'
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-RepoPath` | Yes | — | Absolute path to the repo on the Windows side |
| `-WslDistro` | Yes | — | WSL2 distro name (check with `wsl -l -v`) |
| `-WslRepoPath` | Yes | — | Absolute path to the repo inside WSL |
| `-Watch` | No | `false` | Keep running and mirror changes after initial sync |
| `-BaseBranch` | No | `master` | Branch to diff against (use `main` or `develop` if needed) |
| `-PollMs` | No | `1000` | How often to poll for changes in milliseconds |

## Watch mode output

The screen clears every 3 seconds to stay uncluttered, keeping a running count of tracked files. Each detected change is printed before the next clear:
