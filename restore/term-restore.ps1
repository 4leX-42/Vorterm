# Term restore: after a crash, reboot or forced close, Windows Terminal reopens its tabs/panes
# (firstWindowPreference = persistedLayoutAndContent) and keeps each pane's WT_SESSION id.
# Installed by Vorterm (session restore) in %LOCALAPPDATA%\Vorterm\restore and loaded from its profile block.
# Records live in %LOCALAPPDATA%\TermRestore\<WT_SESSION>.json:
#   - the prompt saves the current folder (and tells WT with OSC 9;9);
#   - the Claude Code hook (term-restore-hook.ps1, next to this file) saves the running session;
#   - a deliberate Claude exit clears it (hook SessionEnd and the claude/claude2 functions).
# On startup the pane goes back to its folder and resumes Claude if it was running.

$script:TrDir = Join-Path $env:LOCALAPPDATA 'TermRestore'
# The real executable, not the 'claude' function below: native install (~\.local\bin\claude.exe)
# or npm (claude.cmd), whichever is on PATH; npm path only as a last resort.
$script:TrClaudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if (-not $script:TrClaudeCmd) { $script:TrClaudeCmd = Join-Path $env:APPDATA 'npm\claude.cmd' }
$script:TrOn = [bool]$env:WT_SESSION -and -not $env:CLAUDECODE -and -not [Console]::IsOutputRedirected

function Get-TrFile { Join-Path $script:TrDir "$env:WT_SESSION.json" }

function Read-TrState {
    $f = Get-TrFile
    if (Test-Path $f) { try { return Get-Content $f -Raw | ConvertFrom-Json } catch {} }
    return $null
}

function Save-TrCwd($cwd) {
    if (-not $script:TrOn) { return }
    New-Item -ItemType Directory -Force $script:TrDir | Out-Null
    $s = Read-TrState
    if (-not $s) { $s = [pscustomobject]@{ cwd = $null; claude = $null; cfg = $null; transcript = $null; at = $null } }
    $s.cwd = $cwd; $s.at = (Get-Date).ToString('s')
    $s | ConvertTo-Json -Compress | Set-Content (Get-TrFile) -Encoding UTF8
}

function Clear-TrClaude {
    $s = Read-TrState
    if ($s -and $s.claude) {
        $s.claude = $null; $s.transcript = $null
        $s | ConvertTo-Json -Compress | Set-Content (Get-TrFile) -Encoding UTF8
    }
}

# Runs Claude; when it returns normally the pane is alive, so it was a deliberate exit.
function Invoke-TrClaude {
    param([object[]]$ArgList)
    try { & $script:TrClaudeCmd @ArgList }
    finally { if ($script:TrOn) { Clear-TrClaude } }
}

function claude { Invoke-TrClaude -ArgList $args }

function Restore-TrSession {
    if (-not $script:TrOn) { return $false }
    Get-ChildItem $script:TrDir -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -ErrorAction SilentlyContinue
    $s = Read-TrState
    if (-not $s -or -not $s.cwd -or -not (Test-Path -LiteralPath $s.cwd)) { return $false }
    Set-Location -LiteralPath $s.cwd
    if ($s.claude) {
        $known = $s.transcript -and (Test-Path -LiteralPath $s.transcript)
        $resume = if ($known) { "--resume $($s.claude)" } else { '--continue' }
        $exe = if ($s.cfg -and $s.cfg -ne (Join-Path $env:USERPROFILE '.claude')) { 'claude2' } else { 'claude' }
        $global:TrRestored = $true
        # Claude started from inside the profile runs as non-interactive (print mode) and exits.
        # Type the command at the first prompt instead, exactly as if the user had typed it.
        if ($exe -eq 'claude2' -and -not (Get-Command claude2 -ErrorAction SilentlyContinue)) {
            $global:TrPendingCmd = "`$env:CLAUDE_CONFIG_DIR = '$($s.cfg)'; claude $resume"
        } else { $global:TrPendingCmd = "$exe $resume" }
        $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($global:TrPendingCmd)
            # AcceptLine() from an event only takes effect on the next key press, so the line sat
            # there waiting. Queue a real Enter in this console's own input instead.
            if (-not (Send-TrEnter)) { [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine() }
        }
    }
    return $true
}

# Puts an Enter key press in this console's input buffer (only this pane, not the focused window).
function global:Send-TrEnter {
    try {
        if (-not ('TrConIn' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class TrConIn {
    [StructLayout(LayoutKind.Explicit)] public struct REC { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY Key; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct KEY {
        public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode;
        public char UnicodeChar; public uint dwControlKeyState; }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool WriteConsoleInput(IntPtr h, REC[] r, uint n, out uint w);
    public static bool Enter() {
        var r = new REC[2];
        for (int i = 0; i < 2; i++) {
            r[i].EventType = 1; r[i].Key.bKeyDown = i == 0 ? 1 : 0; r[i].Key.wRepeatCount = 1;
            r[i].Key.wVirtualKeyCode = 13; r[i].Key.wVirtualScanCode = 28; r[i].Key.UnicodeChar = '\r';
        }
        uint w; return WriteConsoleInput(GetStdHandle(-10), r, 2, out w) && w == 2;
    }
}
'@
        }
        return [TrConIn]::Enter()
    } catch { return $false }
}

# Prompt hook: tell Windows Terminal the folder (OSC 9;9) and keep the record up to date.
if ($script:TrOn) {
    $script:TrPrompt = $function:prompt
    $script:TrLastCwd = $null
    function global:prompt {
        $p = (Get-Location)
        if ($p.Provider.Name -eq 'FileSystem') {
            $path = $p.ProviderPath
            [Console]::Write("$([char]27)]9;9;`"$path`"$([char]27)\")
            if ($path -ne $script:TrLastCwd) { $script:TrLastCwd = $path; try { Save-TrCwd $path } catch {} }
        }
        & $script:TrPrompt
    }
}
