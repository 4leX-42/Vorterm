<#
.SYNOPSIS
    Gives Codex CLI (OpenAI) the same plugins, MCP servers and skills as Claude Code.

.DESCRIPTION
    Runs after "claude code config" when "codex cli" is ticked; also usable on its own. Reads the
    Claude Code configuration and never changes it. Safe to run again whenever Claude changes.

    1. Plugins  The plugins enabled in ~\.claude\settings.json: their marketplaces (the same local
                folders Claude uses) are added to Codex and each plugin is installed if Codex sees it.
    2. MCP      Servers from ~\.claude.json (mcpServers) plus those of enabled plugins Codex could not
                install go into ~\.codex\config.toml between "# >>> Vorterm" and "# <<< Vorterm"
                (the block is rewritten whole; anything else in the file is kept). On Windows, npx and
                other .cmd launchers are started through cmd /c, because Codex does not use PATHEXT.
    3. Skills   Junctions in ~\.agents\skills (Codex's user skills folder) to the skills of the Claude
                profile and of plugins without a Codex version. Real folders there are never touched.
    4. Rules    project_doc_fallback_filenames = ["CLAUDE.md"], so Codex reads the CLAUDE.md files of
                a project as it reads AGENTS.md; ~\.codex\AGENTS.md is written only if it is missing.

    Codex sign-in is interactive and left to you: run "codex login" once.
    Claude Code hooks (RTK, status line, session restore) have no Codex equivalent and are not copied.

    Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    .\claude\Set-VortermCodex.ps1 -DryRun
#>
param([switch]$DryRun, [scriptblock]$Log, [switch]$PassThru)

$ErrorActionPreference = 'Continue'
$script:fail = @()
function L([string]$m) { if ($Log) { & $Log $m } else { Write-Host $m } }
$tag = if ($DryRun) { 'DRY' } else { 'OK' }
$utf8 = New-Object System.Text.UTF8Encoding $false
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$codexDir = Join-Path $env:USERPROFILE '.codex'
$skillsDir = Join-Path $env:USERPROFILE '.agents\skills'
$configPath = Join-Path $codexDir 'config.toml'

$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') +
            ";$env:USERPROFILE\.local\bin;$env:LOCALAPPDATA\Microsoft\WinGet\Links"

function Read-Json($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $raw = [IO.File]::ReadAllText($path)
    if (-not $raw.Trim()) { return }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { }
    # ~\.claude.json can hold project keys that differ only in case, which ConvertFrom-Json rejects:
    # read it as a dictionary and keep only mcpServers.
    if ($PSVersionTable.PSVersion.Major -ge 6) { $h = $raw | ConvertFrom-Json -AsHashtable }
    else {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        $h = $js.DeserializeObject($raw)
    }
    if ($h -and $h.ContainsKey('mcpServers')) {
        [pscustomobject]@{ mcpServers = ($h['mcpServers'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
    }
}
function Get-Config { if (Test-Path -LiteralPath $configPath) { [IO.File]::ReadAllText($configPath) } else { '' } }
function ConvertTo-TomlString([string]$s) { '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
function Get-McpServers($obj) {
    if (-not $obj) { return @() }
    if ($obj.mcpServers) { $obj = $obj.mcpServers }
    @($obj.PSObject.Properties | Where-Object { $_.Value -is [psobject] })
}
function Get-LatestDir($path) {
    if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
}
function Invoke-Codex([string[]]$CodexArgs) {
    $o = & codex @CodexArgs 2>&1 | Out-String
    [pscustomobject]@{ Out = $o; Code = $LASTEXITCODE }
}

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    L '  [!!] Codex CLI not found: tick "codex cli" (or install it) and run again'
    $script:fail += 'codex:missing'
} elseif (-not (Test-Path -LiteralPath $claudeDir)) {
    L '  [..] no Claude Code profile (~\.claude) to copy from: skipped'
} else {
    if (-not (Test-Path -LiteralPath $codexDir) -and -not $DryRun) { New-Item -ItemType Directory -Path $codexDir -Force | Out-Null }

    # ---- 1. plugins -------------------------------------------------------------------------------
    L '  -- Codex: plugins from Claude Code'
    $settings = Read-Json (Join-Path $claudeDir 'settings.json')
    $known = Read-Json (Join-Path $claudeDir 'plugins\known_marketplaces.json')
    $enabled = @()
    if ($settings -and $settings.PSObject.Properties['enabledPlugins'] -and $settings.enabledPlugins) {
        $enabled = @($settings.enabledPlugins.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object Name)
    }
    $cfg = Get-Config
    foreach ($m in ($enabled | ForEach-Object { ($_ -split '@')[1] } | Sort-Object -Unique)) {
        $loc = if ($known -and $known.PSObject.Properties[$m]) { $known.$m.installLocation }
        if (-not $loc -or -not (Test-Path -LiteralPath $loc)) { L "  [..] marketplace $m is not on disk: skipped"; continue }
        if ($cfg -match "(?m)^\[marketplaces\.`"?$([regex]::Escape($m))`"?\]") { continue }
        if ($DryRun) { L "  [DRY] codex plugin marketplace add $loc"; continue }
        $r = Invoke-Codex @('plugin', 'marketplace', 'add', $loc)
        if ($r.Code) { L "  [..] Codex does not accept marketplace ${m}: $(($r.Out.Trim() -split "`n")[-1])" } else { L "  [OK] marketplace $m" }
    }
    $available = (Invoke-Codex @('plugin', 'list')).Out
    $cfg = Get-Config
    $pending = @()   # enabled in Claude but no Codex version: their MCP servers and skills are copied by hand
    foreach ($p in $enabled) {
        if ($cfg -match [regex]::Escape("[plugins.`"$p`"]")) { L "  [OK] plugin $p"; continue }
        if ($available -notmatch "(?m)^$([regex]::Escape($p))\s") { $pending += $p; continue }
        if ($DryRun) { L "  [DRY] codex plugin add $p"; continue }
        $r = Invoke-Codex @('plugin', 'add', $p)
        if ($r.Code) { $pending += $p } else { L "  [OK] plugin $p" }
    }
    foreach ($p in $pending) { L "  [..] no Codex version of ${p}: its MCP servers and skills are copied instead" }

    # Plugin hooks written for Claude Code start with "bash" and use ${CLAUDE_PLUGIN_ROOT}. Codex on
    # Windows runs hook commands with PowerShell: "bash" resolves to WSL's System32\bash.exe (exit 1
    # when WSL is missing or broken: "Hook failed" on every tool call) and ${CLAUDE_PLUGIN_ROOT} is read
    # as an empty PowerShell variable. Point them at Git Bash (& "path", valid in PowerShell) and the
    # plugin folder. Codex asks once to trust the changed hooks.
    $gitBash = $null
    $g = Get-Command git -ErrorAction SilentlyContinue
    foreach ($c in @($(if ($g) { Join-Path (Split-Path (Split-Path $g.Source)) 'bin\bash.exe' }), "$env:ProgramFiles\Git\bin\bash.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { $gitBash = $c.Replace('\', '/'); break }
    }
    $hookFiles = @(Get-ChildItem -LiteralPath (Join-Path $codexDir 'plugins\cache') -Recurse -Filter 'hooks.json' -Force -ErrorAction SilentlyContinue |
                   Where-Object { $_.Directory.Name -eq 'hooks' })
    foreach ($hf in $hookFiles) {
        $raw = [IO.File]::ReadAllText($hf.FullName)
        $root = $hf.Directory.Parent.FullName.Replace('\', '/')
        $new = $raw.Replace('${CLAUDE_PLUGIN_ROOT}', $root)
        if ($gitBash) { $new = [regex]::Replace($new, '("command"\s*:\s*")bash\s', ('$1& \"' + $gitBash + '\" ')) }
        if ($new -eq $raw) { continue }
        $plug = $hf.Directory.Parent.Parent.Name
        if ($DryRun) { L "  [DRY] hooks of $plug -> Git Bash and plugin path"; continue }
        [IO.File]::WriteAllText($hf.FullName, $new, $utf8)
        L "  [OK] hooks of $plug use Git Bash and the plugin path"
    }

    # ---- 2. MCP servers -----------------------------------------------------------------------------
    L '  -- Codex: MCP servers'
    $taken = @{}   # names a Codex plugin already brings
    $codexCache = Join-Path $codexDir 'plugins\cache'
    if (Test-Path -LiteralPath $codexCache) {
        Get-ChildItem -LiteralPath $codexCache -Recurse -Filter '.mcp.json' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.github\\' } |
            ForEach-Object { Get-McpServers (Read-Json $_.FullName) | ForEach-Object { $taken[$_.Name] = $true } }
    }
    $servers = [ordered]@{}
    foreach ($s in (Get-McpServers (Read-Json (Join-Path $env:USERPROFILE '.claude.json')))) { $servers[$s.Name] = @{ def = $s.Value; root = $null } }
    foreach ($p in $pending) {
        $name, $market = $p -split '@'
        $dir = Get-LatestDir (Join-Path $claudeDir "plugins\cache\$market\$name")
        if (-not $dir) { continue }
        foreach ($s in (Get-McpServers (Read-Json (Join-Path $dir.FullName '.mcp.json')))) {
            if (-not $servers.Contains($s.Name)) { $servers[$s.Name] = @{ def = $s.Value; root = $dir.FullName } }
        }
    }
    $lines = @('# >>> Vorterm: MCP servers copied from Claude Code (claude\Set-VortermCodex.ps1 rewrites this block)')
    $written = @()
    foreach ($n in $servers.Keys) {
        if ($taken[$n]) { L "  [OK] mcp $n (comes with a Codex plugin)"; continue }
        $d = $servers[$n].def; $root = $servers[$n].root
        $lines += ''
        $lines += "[mcp_servers.$(ConvertTo-TomlString $n)]"
        if ($d.PSObject.Properties['url'] -and $d.url) {
            $lines += "url = $(ConvertTo-TomlString $d.url)"
        } else {
            $cmd = [string]$d.command
            $argList = @($d.args | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ })
            if ($root) { $argList = @($argList | ForEach-Object { $_.Replace('${CLAUDE_PLUGIN_ROOT}', $root) }) }
            if ($cmd -notmatch '[\\/]' -and $cmd -notmatch '\.exe$') {
                $hits = @(where.exe $cmd 2>$null)
                if (-not ($hits -match '\.exe$') -and ($hits -match '\.(cmd|bat)$')) { $argList = @('/c', $cmd) + $argList; $cmd = 'cmd' }
            }
            $lines += "command = $(ConvertTo-TomlString $cmd)"
            if ($argList.Count) { $lines += 'args = [' + (($argList | ForEach-Object { ConvertTo-TomlString $_ }) -join ', ') + ']' }
            $envMap = [ordered]@{}
            if ($d.PSObject.Properties['env'] -and $d.env) { $d.env.PSObject.Properties | ForEach-Object { $envMap[$_.Name] = [string]$_.Value } }
            if ($root) { $envMap['CLAUDE_PLUGIN_ROOT'] = $root; $envMap['PLUGIN_ROOT'] = $root }
            if ($envMap.Count) { $lines += 'env = { ' + (($envMap.Keys | ForEach-Object { "$_ = $(ConvertTo-TomlString $envMap[$_])" }) -join ', ') + ' }' }
        }
        $written += $n
        L "  [$tag] mcp $n"
    }
    $lines += '# <<< Vorterm'

    # ---- 4. rules (a root key: it must come before any table) ---------------------------------------
    $cfg = Get-Config
    $cfg = [regex]::Replace($cfg, '(?s)\r?\n?# >>> Vorterm.*?# <<< Vorterm\r?\n?', "`n")
    if ($cfg -notmatch '(?m)^project_doc_fallback_filenames') {
        $cfg = "project_doc_fallback_filenames = [`"CLAUDE.md`"]`n`n" + $cfg.TrimStart()
    }
    $newCfg = $cfg.TrimEnd() + "`n`n" + ($lines -join "`n") + "`n"
    if ($DryRun) { L "  [DRY] would write $configPath ($($written.Count) MCP servers, CLAUDE.md as project doc)" }
    else {
        if (Test-Path -LiteralPath $configPath) {
            $old = [IO.File]::ReadAllText($configPath)
            if ($old -ne $newCfg) { Copy-Item -LiteralPath $configPath "$configPath.vorterm-bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force }
        }
        [IO.File]::WriteAllText($configPath, $newCfg, $utf8)
        L "  [OK] $configPath ($($written.Count) MCP servers, CLAUDE.md read as project instructions)"
    }
    $agentsMd = Join-Path $codexDir 'AGENTS.md'
    if (Test-Path -LiteralPath $agentsMd) { L "  [OK] $agentsMd kept as it is" }
    elseif ($DryRun) { L "  [DRY] would write $agentsMd" }
    else {
        [IO.File]::WriteAllText($agentsMd, ((@'
# Global rules (written by Vorterm; yours to edit, Vorterm never overwrites it)

- The CLAUDE.md files of a project are its instructions: follow them as you would an AGENTS.md.
- Skills shared with Claude Code are in ~/.agents/skills.
- Never store secrets in project files.
'@) -replace "`r?`n", "`n"), $utf8)
        L "  [OK] $agentsMd"
    }

    # ---- 3. skills ----------------------------------------------------------------------------------
    L '  -- Codex: skills'
    $sources = [ordered]@{}
    $base = Join-Path $claudeDir 'skills'
    if (Test-Path -LiteralPath $base) {
        Get-ChildItem -LiteralPath $base -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object {
            $target = if ($_.LinkType) { [string]@($_.Target)[0] } else { $_.FullName }
            $sources[$_.Name] = $target
        }
    }
    foreach ($p in $pending) {
        $name, $market = $p -split '@'
        $dir = Get-LatestDir (Join-Path $claudeDir "plugins\cache\$market\$name")
        if (-not $dir -or -not (Test-Path (Join-Path $dir.FullName 'skills'))) { continue }
        Get-ChildItem (Join-Path $dir.FullName 'skills') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
            ForEach-Object { $sources["$name-$($_.Name)"] = $_.FullName }
    }
    if (-not (Test-Path -LiteralPath $skillsDir) -and -not $DryRun -and $sources.Count) { New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null }
    foreach ($n in $sources.Keys) {
        $link = Join-Path $skillsDir $n
        $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -and ([string]@($item.Target)[0]).TrimEnd('\') -eq $sources[$n].TrimEnd('\')) { L "  [OK] skill $n"; continue }
        if ($item -and -not $item.LinkType) { L "  [..] skill $n is a real folder in $skillsDir`: left alone"; continue }
        if ($DryRun) { L "  [DRY] junction $n -> $($sources[$n])"; continue }
        try {
            if ($item) { $item.Delete() }   # old junction to another path: only the link goes
            New-Item -ItemType Junction -Path $link -Target $sources[$n] | Out-Null
            L "  [OK] skill $n"
        } catch { L "  [!!] skill ${n}: $($_.Exception.Message)"; $script:fail += "codex-skill:$n" }
    }

    # ---- check --------------------------------------------------------------------------------------
    if (-not $DryRun) {
        $list = (Invoke-Codex @('mcp', 'list')).Out
        $missing = @($written | Where-Object { $list -notmatch "(?m)^$([regex]::Escape($_))\s" })
        if ($missing.Count) { L "  [!!] codex mcp list does not show: $($missing -join ', ')"; $script:fail += 'codex-mcp' }
        else { L "  [OK] codex mcp list shows all $($written.Count) MCP servers" }
        if ((Invoke-Codex @('login', 'status')).Code) { L '  [..] Codex is not signed in yet: run "codex login" once' }
    }
}

if ($PassThru) { [pscustomobject]@{ Ok = ($script:fail.Count -eq 0); Failures = $script:fail } }
elseif ($script:fail.Count -gt 0) { exit 1 }
