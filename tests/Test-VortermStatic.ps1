<#
.SYNOPSIS
    READ-ONLY. Static checks of the Vorterm repository: no installer is run.

.DESCRIPTION
    - every .ps1 parses on Windows PowerShell 5.1 and PowerShell 7 (when available)
    - the install/reset logic blocks re-parse as text (that is how the GUI runspace runs them)
    - .ps1 and .bat files are pure ASCII (PS 5.1 reads BOM-less UTF-8 as Windows-1252)
    - JSON files (theme, LAB manifest, LAB template) are valid
    - the embedded fallback theme equals Mainthema.json
    - the WPF window XAML loads (no window is shown)
    - gitleaks scan of the repository when gitleaks is installed
    Exit code 0 when everything passes.

.NOTES
    Context: user. Permissions: none. Modules: none.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fail = 0
function Report([bool]$Ok, [string]$Msg) {
    if ($Ok) { Write-Host "[PASS] $Msg" -ForegroundColor Green } else { Write-Host "[FAIL] $Msg" -ForegroundColor Red; $script:fail++ }
}

# -Include is ignored together with -LiteralPath on Windows PowerShell 5.1: filter by extension.
function Get-RepoFiles([string[]]$Ext) {
    @(Get-ChildItem -LiteralPath $repo -Recurse -File -Force |
        Where-Object { $Ext -contains $_.Extension.ToLowerInvariant() -and $_.FullName -notmatch '\\\.git\\' })
}
$ps1 = Get-RepoFiles @('.ps1')

foreach ($f in $ps1) {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
    Report ($e.Count -eq 0) ("parse PS{0} {1}" -f $PSVersionTable.PSVersion.Major, $f.FullName.Substring($repo.Length + 1))
}

$other = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
if ($other -and (Test-Path -LiteralPath $other)) {
    $list = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllLines($list, [string[]]$ps1.FullName)
    $cmd = "foreach (`$p in [IO.File]::ReadAllLines('$list')) { `$e = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile(`$p, [ref]`$null, [ref]`$e); '{0}|{1}' -f `$p, `$e.Count }"
    $out = & $other -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
    Remove-Item -LiteralPath $list -Force
    foreach ($o in $out) {
        $p = ([string]$o) -split '\|'
        if ($p.Count -eq 2) { Report ($p[1] -eq '0') ("parse other engine {0}" -f $p[0].Substring($repo.Length + 1)) }
    }
}

$setup = Join-Path $repo 'setup_terminal.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($setup, [ref]$null, [ref]$null)
foreach ($n in 'InstallLogic', 'ResetLogic') {
    $a = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -eq "`$$n" }, $false) | Select-Object -First 1
    $t = $a.Right.Extent.Text
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($t.Substring(1, $t.Length - 2), [ref]$null, [ref]$e)
    Report ($e.Count -eq 0) "re-parse `$$n as text"
}

foreach ($f in @($ps1) + @(Get-RepoFiles @('.bat', '.cmd'))) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $bad = @($b | Where-Object { $_ -gt 127 }).Count
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bad -= 3 }
    Report ($bad -eq 0) ("ASCII {0}" -f $f.FullName.Substring($repo.Length + 1))
}

$json = @(Get-RepoFiles @('.json', '.example') | Where-Object { $_.Name -like '*.json' -or $_.Name -like '*.json.example' })
foreach ($f in $json) {
    $ok = $true
    try { [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json | Out-Null } catch { $ok = $false }
    Report $ok ("JSON {0}" -f $f.FullName.Substring($repo.Length + 1))
}

$text = [IO.File]::ReadAllText($setup)
$s = $text.IndexOf("`$script:ThemeJson = @'") + 22
$emb = $text.Substring($s, $text.IndexOf("'@", $s) - $s) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
$thm = [IO.File]::ReadAllText((Join-Path $repo 'Mainthema.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
Report ($emb -eq $thm) 'embedded fallback theme equals Mainthema.json'

$x0 = $text.IndexOf("[xml]`$xaml = @'") + 15
$xamlText = $text.Substring($x0, $text.IndexOf("'@", $x0) - $x0)
$ps = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { $null }
$xamlFile = [IO.Path]::GetTempFileName()
[IO.File]::WriteAllText($xamlFile, $xamlText)
$probe = "Add-Type -AssemblyName PresentationFramework; [xml]`$x = [IO.File]::ReadAllText('$xamlFile'); `$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader `$x)); foreach (`$n in 'cb_lab','LabPanel','LabPathBox','LabBrowseBtn','LabTarget','cb_node','cb_multipane','cb_restore','SetupPanel','StartupRow','ConfigRow','OptionsBtn') { if (-not `$w.FindName(`$n)) { throw ""missing `$n"" } }; 'XAML_OK'"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
$res = if ($ps) { & $ps -NoProfile -STA -EncodedCommand $enc 2>&1 } else { & powershell.exe -NoProfile -STA -EncodedCommand $enc 2>&1 }
Remove-Item -LiteralPath $xamlFile -Force
Report (($res | Out-String) -match 'XAML_OK') 'XAML loads and has the LAB / node / multi-pane controls'

$gl = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($gl) {
    # gitleaks logs to stderr: on Windows PowerShell 5.1 that is an error record, fatal under Stop.
    $ErrorActionPreference = 'Continue'
    $null = & $gl.Source dir $repo --no-banner --redact 2>&1
    $ErrorActionPreference = 'Stop'
    Report ($LASTEXITCODE -eq 0) 'gitleaks: no secrets found'
} else {
    Write-Host '[SKIP] gitleaks not installed'
}

Write-Host ("Static checks finished: {0} failure(s)" -f $fail)
if ($fail -gt 0) { exit 1 }
exit 0
