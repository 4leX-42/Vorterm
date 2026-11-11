<#
.SYNOPSIS
    Vorterm "claude code config": one switch that sets up Claude Code completely.

.DESCRIPTION
    1. Permissions: bypassPermissions as the default mode, no start-up warning, deny rules for
       secrets. Written to ~/.claude/settings.json and ~/.claude2/settings.json and enforced again
       on every run (other keys in those files are kept).
    2. Plugins, MCP servers and tools: runs the Claude Code Setup Guide engine
       (github.com/4leX-42/ClaudeCode_SETUP) with its "essentials" manifest and --second-profile.
    3. Status line: 5-hour / weekly usage and context percent (only if you have none).
    4. Workspace: a generic lab folder structure with a CLAUDE.md (only files that are missing).

    WARNING: with bypassPermissions Claude runs commands and edits files without asking, including
    whatever a plugin or a prompt injection hidden in a web page or a repository tells it to do.
    The deny rules still apply. An organisation policy (disableBypassPermissionsMode) overrides it.

    Windows PowerShell 5.1 and PowerShell 7. Called by setup_terminal.ps1; also usable on its own.

.EXAMPLE
    .\claude\Set-VortermClaude.ps1 -WorkDir "$env:USERPROFILE\Documents"
    .\claude\Set-VortermClaude.ps1 -WorkDir D:\Work -EngineDir C:\src\ClaudeCode_SETUP -DryRun
#>
param(
    [string]$WorkDir = [Environment]::GetFolderPath('MyDocuments'),
    [string]$Pwsh,
    [string]$EngineDir,                  # local ClaudeCode_SETUP copy (default: download main)
    [string]$EngineZip = 'https://github.com/4leX-42/ClaudeCode_SETUP/archive/refs/heads/main.zip',
    [switch]$NoSecondProfile,
    [switch]$NoWorkspace,
    [int]$EngineTimeoutMin = 30,
    [int]$EngineStallMin = 10,
    [switch]$DryRun,
    [scriptblock]$Log,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$script:fail = @()
# Tests point the engine at an unpublished copy without changing the call from setup_terminal.ps1.
if (-not $EngineDir -and $env:VORTERM_CLAUDE_ENGINE_DIR) { $EngineDir = $env:VORTERM_CLAUDE_ENGINE_DIR }
function L([string]$m) { if ($Log) { & $Log $m } else { Write-Host $m } }
$utf8 = New-Object System.Text.UTF8Encoding $false
$tag = if ($DryRun) { 'DRY' } else { 'OK' }

$cfgDirs = @(Join-Path $env:USERPROFILE '.claude')
if (-not $NoSecondProfile) { $cfgDirs += (Join-Path $env:USERPROFILE '.claude2') }

$deny = @('Read(./.env)', 'Read(**/.env)', 'Read(**/.env.*)', 'Read(**/.ssh/**)', 'Read(**/*.pem)',
          'Read(**/*.pfx)', 'Read(**/*.key)', 'Read(**/.claude/.credentials.json)',
          'Read(**/.aws/credentials)', 'Read(**/.azure/**)')

function Update-ClaudeSettings([string]$Dir, [scriptblock]$Change, [string]$What) {
    $f = Join-Path $Dir 'settings.json'
    try {
        $j = $null
        if (Test-Path -LiteralPath $f) { $raw = [IO.File]::ReadAllText($f); if ($raw.Trim()) { $j = $raw | ConvertFrom-Json } }
        if (-not $j) { $j = New-Object psobject }
        $before = $j | ConvertTo-Json -Depth 32 -Compress
        & $Change $j
        $after = $j | ConvertTo-Json -Depth 32 -Compress
        if ($before -eq $after) { L "  [OK] $What already set ($f)"; return }
        if ($DryRun) { L "  [DRY] $What -> $f"; return }
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
        if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f "$f.vorterm-bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force }
        [IO.File]::WriteAllText($f, ($j | ConvertTo-Json -Depth 32), $utf8)
        L "  [OK] $What -> $f"
    } catch {
        L "  [!!] $What ($f): $($_.Exception.Message)"
        $script:fail += "settings:$Dir"
    }
}
function Set-Prop($o, [string]$n, $v) { if ($o.PSObject.Properties[$n]) { $o.$n = $v } else { $o | Add-Member -MemberType NoteProperty -Name $n -Value $v } }

# Bypass is the rule of this switch: it is written first (works offline) and again at the end, so
# nothing the engine or a plugin installer does can leave it off.
function Set-Bypass {
    foreach ($d in $cfgDirs) {
        Update-ClaudeSettings $d {
            param($j)
            Set-Prop $j 'skipDangerousModePermissionPrompt' $true
            if (-not $j.PSObject.Properties['permissions'] -or -not $j.permissions) { Set-Prop $j 'permissions' (New-Object psobject) }
            Set-Prop $j.permissions 'defaultMode' 'bypassPermissions'
            $cur = @(); if ($j.permissions.PSObject.Properties['deny']) { $cur = @($j.permissions.deny | Where-Object { $_ }) }
            $add = @($deny | Where-Object { $cur -notcontains $_ })
            if ($add.Count -gt 0 -or -not $j.permissions.PSObject.Properties['deny']) { Set-Prop $j.permissions 'deny' (@($cur) + $add) }
        } 'bypassPermissions + deny rules'
    }
}

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') +
                ";$env:USERPROFILE\.local\bin;$env:LOCALAPPDATA\Microsoft\WinGet\Links"
}

# ---- 1. permissions ---------------------------------------------------------------------------
L '  -- permissions'
Set-Bypass

# ---- 2. engine: plugins, MCP servers, tools, second profile -----------------------------------
L '  -- plugins, MCP servers and tools (Claude Code Setup Guide, essentials)'
Update-Path
if (-not $Pwsh) { $c = Get-Command pwsh -ErrorAction SilentlyContinue; if ($c) { $Pwsh = $c.Source } }
$claude = Get-Command claude -ErrorAction SilentlyContinue
$engineRoot = $null
if (-not $Pwsh) {
    L '  [!!] PowerShell 7 not found: plugins and MCP servers skipped (the engine needs pwsh)'
    $script:fail += 'engine:pwsh'
} elseif (-not $claude) {
    L '  [!!] Claude Code CLI not found: plugins and MCP servers skipped (tick "claude code" or install it, then run again)'
    $script:fail += 'engine:claude'
} else {
    try {
        if ($EngineDir) {
            $engineRoot = (Resolve-Path $EngineDir).Path
        } else {
            $base = Join-Path $env:LOCALAPPDATA 'Vorterm\claude-setup'
            if ($DryRun) {
                L "  [DRY] would download $EngineZip -> $base"
            } else {
                if (Test-Path $base) { Remove-Item $base -Recurse -Force }
                New-Item -ItemType Directory -Path $base -Force | Out-Null
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $zip = Join-Path $base 'engine.zip'
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $EngineZip -OutFile $zip -UseBasicParsing -TimeoutSec 120
                Expand-Archive -LiteralPath $zip -DestinationPath $base -Force
                $engineRoot = (Get-ChildItem $base -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1).FullName
            }
        }
        if ($engineRoot) {
            $manifest = Join-Path $engineRoot 'profiles\essentials.json'
            if (-not (Test-Path $manifest)) { throw "profiles\essentials.json not found in $engineRoot" }
            $logDir = Join-Path $env:LOCALAPPDATA 'Vorterm\logs'
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $stamp = Get-Date -Format yyyyMMdd-HHmmss
            $out = Join-Path $logDir "claude-setup-$stamp.log"; $report = Join-Path $logDir "claude-setup-$stamp.json"
            $engArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $engineRoot 'scripts\setup.ps1')`" --apply --manifest `"$manifest`" --report text --report-path `"$report`""
            if (-not $NoSecondProfile) { $engArgs += ' --second-profile' }
            if ($DryRun) { $engArgs = $engArgs.Replace('--apply', '--apply --dry-run') }
            L "  [..] running the engine (log: $out)"
            $p = Start-Process -FilePath $Pwsh -ArgumentList $engArgs -WorkingDirectory $engineRoot -PassThru -WindowStyle Hidden `
                               -RedirectStandardOutput $out -RedirectStandardError "$out.err"
            $null = $p.Handle   # keeps the handle: without it ExitCode is empty after exit (PowerShell quirk)
            # Watchdog: overall deadline and a stall limit; engine lines are forwarded as they come.
            $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = 0; $lastGrow = $sw.Elapsed; $why = $null
            while (-not $p.HasExited) {
                Start-Sleep -Seconds 2
                $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $seen) {
                    $lines[$seen..($lines.Count - 1)] | Where-Object { $_.Trim() } | ForEach-Object { L "       $($_.TrimEnd())" }
                    $seen = $lines.Count; $lastGrow = $sw.Elapsed
                }
                if ($sw.Elapsed.TotalMinutes -gt $EngineTimeoutMin) { $why = "over $EngineTimeoutMin min" }
                elseif (($sw.Elapsed - $lastGrow).TotalMinutes -gt $EngineStallMin) { $why = "no output for $EngineStallMin min" }
                if ($why) { & taskkill.exe /T /F /PID $p.Id | Out-Null; break }
            }
            $p.WaitForExit()
            $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] | Where-Object { $_.Trim() } | ForEach-Object { L "       $($_.TrimEnd())" } }
            if ($why) {
                L "  [!!] engine stopped: $why (log: $out)"; $script:fail += 'engine:hang'
            } elseif ($p.ExitCode -ne 0) {
                L "  [!!] engine finished with exit $($p.ExitCode) (details: $out)"; $script:fail += 'engine'
            } else {
                L "  [$tag] plugins, MCP servers and tools converged (report: $report)"
            }
        }
    } catch {
        L "  [!!] engine: $($_.Exception.Message)"
        $script:fail += 'engine'
    }
}

# ---- 3. status line ---------------------------------------------------------------------------
L '  -- status line'
$sl = if ($engineRoot) { Join-Path $engineRoot 'extras\statusline\statusline-usage.ps1' } else { $null }
if (-not $sl -or -not (Test-Path -LiteralPath $sl)) {
    L '  [..] status line script not available (engine not downloaded): skipped'
} else {
    foreach ($d in $cfgDirs) {
        if (-not (Test-Path -LiteralPath $d) -and -not $DryRun) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        $dst = Join-Path $d 'statusline-usage.ps1'
        if (-not $DryRun) { Copy-Item -LiteralPath $sl -Destination $dst -Force }
        $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$dst`""
        Update-ClaudeSettings $d {
            param($j)
            if (-not $j.PSObject.Properties['statusLine'] -or -not $j.statusLine) {
                Set-Prop $j 'statusLine' ([pscustomobject][ordered]@{ type = 'command'; command = $cmd })
            }
        } 'status line (kept if you already have one)'
    }
}

# ---- 4. workspace -----------------------------------------------------------------------------
if (-not $NoWorkspace) {
    L '  -- workspace'
    $ws = Join-Path $WorkDir 'claude-lab'
    $files = [ordered]@{
        'README.md' = @'
# claude-lab

Working folder for projects with Claude Code. Open Claude Code here (`cd claude-lab; claude`) and it
reads `CLAUDE.md` first.

| Folder | What goes in it | Git |
|---|---|---|
| `proyectos\<section>\<name>\` | one folder per tool, app or experiment, started from `proyectos\_plantilla\` | yes |
| `scripts\<area>\` | loose support scripts | yes |
| `docs\` | notes for the whole lab; `docs\lecciones\` = lessons learned (error, cause, rule) | yes |
| `privado\` | credentials, exports, personal data | **never** |
| `_archivo\` | things you are not sure you can delete | **never** |

Sections are up to you (for example `work`, `home`, `learning`).
'@
        'CLAUDE.md' = @'
# Lab rules for Claude

## Structure

See `README.md`. New work goes in `proyectos\<section>\<name>\`, copied from `proyectos\_plantilla\`,
with a line in `proyectos\README.md`. Loose scripts go in `scripts\<area>\`.

## Rules

- Before starting a topic, read its lesson in `docs\lecciones\` if there is one. When something
  fails or I correct you, write a lesson there: what happened, the cause, the rule.
- No absolute paths in files that go to git: use relative paths or `$PSScriptRoot`.
- Nothing from `privado\` or `_archivo\` goes into versioned files, commits or anything published.
  Before publishing, scan for secrets (gitleaks) and personal data.
- One copy of each project. Do not delete blindly: move to `_archivo\` and say so.
- Anything that installs software or changes the system is tested in a virtual machine or a
  sandbox first, never straight on this computer.
- Git: branch, pull request, merge. Only the files of the task in each commit.
- Plan, do, verify, then report what was done and what was not, with the evidence.
'@
        '.gitignore' = "privado/`r`n_archivo/`r`n*.log`r`n.env`r`n.env.*`r`n"
        'proyectos\README.md' = "# Projects`r`n`r`n| Project | Section | Type | Status |`r`n|---|---|---|---|`r`n"
        'proyectos\_plantilla\README.md' = "# <name>`r`n`r`nWhat it is, how to run it, where it stands.`r`n"
        'proyectos\_plantilla\TODO.md' = "# TODO`r`n`r`n- [ ] first step`r`n"
        'scripts\README.md' = "# Scripts`r`n`r`nOne folder per area. Each script says at the top what it does and how to run it.`r`n"
        'docs\lecciones\README.md' = "# Lessons`r`n`r`nOne file per lesson: what happened (date), the cause, the rule.`r`n"
        'privado\README.md' = "Private: never in git, never published.`r`n"
        '_archivo\README.md' = "Archive: things kept until it is clear they can be deleted. Never in git.`r`n"
    }
    try {
        $new = 0; $kept = 0
        foreach ($k in $files.Keys) {
            $p = Join-Path $ws $k
            if (Test-Path -LiteralPath $p) { $kept++; continue }
            $new++
            if ($DryRun) { continue }
            $dir = Split-Path $p
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllText($p, ($files[$k] -replace "`r?`n", "`r`n"), $utf8)
        }
        L ("  [{0}] {1}: {2} files created, {3} already there (never overwritten)" -f $tag, $ws, $new, $kept)
    } catch {
        L "  [!!] workspace: $($_.Exception.Message)"
        $script:fail += 'workspace'
    }
}

# ---- again: the rule holds whatever ran in between --------------------------------------------
L '  -- permissions (check)'
Set-Bypass

if ($PassThru) { [pscustomobject]@{ Ok = ($script:fail.Count -eq 0); Failures = $script:fail } }
elseif ($script:fail.Count -gt 0) { exit 1 }
