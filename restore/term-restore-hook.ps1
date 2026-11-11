# Claude Code hook for Vorterm session restore (see term-restore.ps1 next to this file).
# Records, per Windows Terminal pane (WT_SESSION), which Claude session is running there, so that
# after a crash, forced close or reboot the pane resumes it. A clean exit clears the record.
# Events: SessionStart, UserPromptSubmit (async; also catches sessions started before the hook)
# and SessionEnd. PS 5.1 compatible, ASCII only. Never fails the hook.
param([string]$Mode = 'Start')
try {
    if (-not $env:WT_SESSION) { exit 0 }
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $j = $raw | ConvertFrom-Json
    if (-not $j.session_id) { exit 0 }
    # Only the interactive Claude that owns the pane: skip print/SDK runs (claude -p from hooks
    # or scripts inherit WT_SESSION) and Claude processes nested inside another Claude.
    $procs = @{}
    Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine |
        ForEach-Object { $procs[[int]$_.ProcessId] = $_ }
    $cur = $procs[$PID]; $owner = $null; $depth = 0
    while ($cur -and $depth -lt 30) {
        if ($cur.Name -eq 'claude.exe') {
            if ($owner) { exit 0 }   # a second claude.exe up the chain: nested
            $owner = $cur
        }
        $cur = $procs[[int]$cur.ParentProcessId]; $depth++
    }
    if (-not $owner) { exit 0 }
    if ($owner.CommandLine -match '(^|\s)(-p|--print|--output-format|--input-format|--sdk-url)(\s|=|$)') { exit 0 }
    $dir = Join-Path $env:LOCALAPPDATA 'TermRestore'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $file = Join-Path $dir ($env:WT_SESSION + '.json')
    $cfg = $env:CLAUDE_CONFIG_DIR
    if (-not $cfg) { $cfg = Join-Path $env:USERPROFILE '.claude' }

    if ($Mode -eq 'End') {
        # Only a deliberate exit clears it. A reboot or a killed window must keep the record.
        if ($j.reason -in @('prompt_input_exit', 'logout') -and (Test-Path $file)) {
            $s = Get-Content $file -Raw | ConvertFrom-Json
            if ($s.claude -eq $j.session_id) {
                $s.claude = $null; $s.transcript = $null
                $s | ConvertTo-Json -Compress | Set-Content $file -Encoding UTF8
            }
        }
        exit 0
    }

    $cwd = $j.cwd
    if (-not $cwd) { $cwd = (Get-Location).Path }
    # The launch folder (where to resume) is kept from the first record of this session.
    if (Test-Path $file) {
        $old = Get-Content $file -Raw | ConvertFrom-Json
        if ($old.claude -eq $j.session_id -and $old.cwd) { $cwd = $old.cwd }
    }
    [pscustomobject]@{
        cwd = $cwd; claude = $j.session_id; cfg = $cfg
        transcript = $j.transcript_path; at = (Get-Date).ToString('s')
    } | ConvertTo-Json -Compress | Set-Content $file -Encoding UTF8
} catch {}
exit 0
