# =============================================================
#  Vorterm 7.2  (WPF GUI)
#  Run via INSTALAR.bat (powershell.exe -STA -WindowStyle Hidden)
#
#  CLI (sin GUI, desatendido / pruebas):
#    powershell -STA -File setup_terminal.ps1 -NoGui [-DryRun]
#    -NoGui        : ejecuta en consola, sin ventana (exit 0 = ok, 1 = avisos)
#    -DryRun       : simula todo, no toca NADA del sistema
#    -WorkDir      : directorio inicial de las pestanas (def. Documents)
#    -LabRoot <p>  : crea el LAB en <p>\LAB (opcional)
#    -LabAdopt     : usa una carpeta LAB existente no creada por Vorterm
#    -Node / -ClaudeCode / -VSCode : componentes opcionales
#    -NoMultiPane  : sin m2/m3/m4 ni perfil Mosaic
#    -Reset        : deshace la configuracion Vorterm (perfiles, modulos, WT)
# =============================================================

[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$DryRun,
    [string]$WorkDir,
    [string]$LabRoot,
    [switch]$LabAdopt,
    [switch]$Node,
    [switch]$ClaudeCode,
    [switch]$VSCode,
    [switch]$NoMultiPane,
    [switch]$Reset,
    [switch]$NoElevate
)

$script:VortermVersion = '7.2'

# ------ PSModulePath de Windows PowerShell ---------------------
# Lanzado desde pwsh 7 (comando de una linea pegado en pwsh) o con un PSModulePath de
# usuario que apunta a PowerShell 7, powershell.exe 5.1 no encuentra sus modulos de
# serie (Get-FileHash, Get-PackageProvider...). Se rehace con las rutas de 5.1.
if ($PSVersionTable.PSVersion.Major -le 5) {
    $docs51 = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    if (-not $docs51) { $docs51 = Join-Path $env:USERPROFILE 'Documents' }
    $mp51 = @((Join-Path $docs51 'WindowsPowerShell\Modules'),
              (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
              (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules'))
    $machineMp = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
    if ($machineMp) { $mp51 += @($machineMp -split ';' | Where-Object { $_ -and $_ -notmatch '\\PowerShell\\[67]' }) }
    $env:PSModulePath = (@($mp51 | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }) |
                         Select-Object -Unique) -join ';'
}

# ------ Elevacion automatica ----------------------------------
# Instaladores de equipo (MSI de PowerShell 7, oh-my-posh, WSL...) necesitan admin.
# Solo se relanza elevado si ESTA cuenta es administradora (token dividido por UAC):
# con una cuenta estandar, elevar con credenciales de otro usuario configuraria el
# perfil y Windows Terminal de ese otro usuario. En ese caso se sigue sin admin y
# PowerShell 7 / oh-my-posh caen a la version portable.
$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsElevated -and -not $NoElevate -and -not $DryRun -and $PSCommandPath) {
    $adminAccount = $false
    try {
        # Con UAC el grupo Administradores (S-1-5-32-544) esta en el token como "solo denegar"
        $adminAccount = [bool](& "$env:SystemRoot\System32\whoami.exe" /groups /fo csv 2>$null | Select-String -SimpleMatch 'S-1-5-32-544')
    } catch {}
    if ($adminAccount) {
        $fwd = @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass')
        if (-not $NoGui) { $fwd += @('-WindowStyle', 'Hidden') }
        $fwd += @('-File', "`"$PSCommandPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $fwd += "-$k" } }
            else { $fwd += @("-$k", "`"$v`"") }
        }
        try {
            $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                 -ArgumentList $fwd -Verb RunAs -PassThru -Wait:([bool]$NoGui)
            if ($NoGui) { exit $p.ExitCode }
            exit 0
        } catch {
            # UAC cancelado: se sigue sin admin (los MSI de equipo pueden fallar)
            Write-Host 'Vorterm: UAC cancelado, se continua sin permisos de administrador.' -ForegroundColor Yellow
        }
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

if (-not $NoGui) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
}

# Process suspend/resume P/Invoke (used for Pause button during install)
if (-not ('Vorterm.ProcCtl' -as [type])) {
    Add-Type -Namespace Vorterm -Name ProcCtl -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtSuspendProcess(System.IntPtr handle);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtResumeProcess(System.IntPtr handle);
'@
}

# DWM: barra de titulo oscura (por defecto Windows la pinta blanca en apps Win32/WPF)
if (-not ('Vorterm.Dwm' -as [type])) {
    Add-Type -Namespace Vorterm -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
}

# ------ Prompt theme (Mainthema) -----------------------------
# Se instala en ~\.poshthemes\Mainthema.json. Prioridad:
#   1. Mainthema.json junto al script (repo)
#   2. Copia embebida (fallback, mismo contenido)
$script:ThemeFileName = 'Mainthema.json'
$script:ThemeSrc = $null
if ($PSScriptRoot) {
    $cand = Join-Path $PSScriptRoot $script:ThemeFileName
    if (Test-Path $cand) { $script:ThemeSrc = $cand }
}
$script:ThemeJson = @'
{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "blocks": [
    {
      "alignment": "left",
      "segments": [
        {
          "foreground": "#FFFFFF",
          "style": "plain",
          "template": "\u250F[\uF17C]",
          "type": "text"
        },
        {
          "foreground": "#00FFFF",
          "options": {
            "style": "agnoster_short",
            "max_depth": 3
          },
          "style": "plain",
          "template": "<#FFFFFF>[</>{{ .Path }}<#FFFFFF>]</>",
          "type": "path"
        },
        {
          "foreground": "#FFA500",
          "style": "plain",
          "template": "<#FFFFFF>[</>\uF007 {{ .UserName }}<#FFFFFF>]</>",
          "type": "session"
        },
        {
          "foreground": "#FF0033",
          "style": "plain",
          "template": "<#FFFFFF>git:</>{{ .HEAD }}",
          "type": "git"
        },
        {
          "foreground": "#FF0033",
          "style": "plain",
          "template": "{{ if gt .Code 0 }} <#FFFFFF>[x</>{{ reason .Code }}<#FFFFFF>]</>{{ end }}",
          "type": "status"
        }
      ],
      "type": "prompt"
    },
    {
      "alignment": "left",
      "newline": true,
      "segments": [
        {
          "foreground": "#FFFFFF",
          "style": "plain",
          "template": "\u2516>",
          "type": "text"
        }
      ],
      "type": "prompt"
    }
  ],
  "final_space": true,
  "version": 4
}
'@

# =============================================================
#  INSTALL LOGIC (compartida: runspace GUI + modo consola)
#  Espera en scope: $sync (hashtable), $opts (hashtable)
# =============================================================
$InstallLogic = {

    function Write-Log {
        param([string]$Msg)
        if ($opts.LogFile) {
            try { [IO.File]::AppendAllText($opts.LogFile, $Msg + [Environment]::NewLine) } catch {}
        }
        if ($sync.NoGui) { Write-Host $Msg; return }
        $sync.Window.Dispatcher.Invoke([action]{
            $color = '#d9d9d9'
            if     ($Msg -match '\[OK\]')  { $color = '#fcee0a' }
            elseif ($Msg -match '\[!!\]')  { $color = '#ff2b4a' }
            elseif ($Msg -match '\[DRY\]') { $color = '#66d9ff' }
            elseif ($Msg -match '\[\.\.\]'){ $color = '#6a6c70' }
            elseif ($Msg -match '^\s*=+')  { $color = '#8a8104' }
            $run = New-Object System.Windows.Documents.Run($Msg)
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($color)
            [void]$sync.LogPara.Inlines.Add($run)
            [void]$sync.LogPara.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
            $sync.LogBox.ScrollToEnd()
        })
    }
    function Set-Status {
        param([string]$Text, [int]$Pct = -1)
        if ($sync.NoGui) { Write-Host ">> $Text" -ForegroundColor DarkYellow; return }
        $sync.Window.Dispatcher.Invoke([action]{
            $sync.StatusText.Text = $Text
            if ($Pct -ge 0) { $sync.Progress.Value = $Pct }
        })
    }

    # Igual que en el runspace de la GUI: 'Continue'. Con 'Stop' (modo -NoGui hereda
    # el del script) cualquier linea de stderr de un exe (pwsh, winget) se convertia
    # en error fatal en PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $started = Get-Date
    $script:failures = @()
    $DRY = [bool]$opts.DryRun

    # Backups propios de Vorterm: una copia "original" la primera vez que se toca un
    # fichero (lo que Reset restaura) + copias rotativas .vorterm-bak-* (max 5). Nunca
    # se tocan los .bak-* que haya creado el usuario.
    function Backup-VortermFile {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $orig = "$Path.vorterm-original"
        if (-not (Test-Path -LiteralPath $orig)) {
            Copy-Item -LiteralPath $Path -Destination $orig -Force
            Write-Log "  [..] original guardado: $orig"
        }
        $bk = "$Path.vorterm-bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item -LiteralPath $Path -Destination $bk -Force
        $leaf = Split-Path $Path -Leaf
        Get-ChildItem -LiteralPath (Split-Path $Path -Parent) -Filter "$leaf.vorterm-bak-*" -File -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip 5 |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }

    try {

        Write-Log "============================================================"
        Write-Log "  Vorterm $($opts.Version) install  $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
        Write-Log "  Startup dir: $($opts.WorkDir)"
        if ($opts.LogFile) { Write-Log "  Log file:    $($opts.LogFile)" }
        if ($DRY) {
        Write-Log "  MODO DRY RUN - simulacion, no se modifica NADA"
        }
        Write-Log "============================================================"
        Write-Log ""

        # ---- Pre-flight ----------------------------------
        Set-Status 'Pre-check' 2

        $isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Log ("  [{0}] admin rights: {1}" -f $(if($isAdmin){'OK'}else{'..'}), $isAdmin)
        if (-not $isAdmin) {
            Write-Log "  [..] sin admin (cuenta estandar o UAC cancelado): PowerShell 7 y oh-my-posh usaran la version portable si winget falla"
        }

        $hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
        Write-Log ("  [{0}] winget available" -f $(if($hasWinget){'OK'}else{'!!'}))

        function Find-Pwsh {
            @(
                (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source,
                "$env:ProgramFiles\PowerShell\7\pwsh.exe",
                "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
                "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe"
            ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        }
        $pwshExe = Find-Pwsh
        Write-Log ("  [{0}] pwsh.exe: {1}" -f $(if($pwshExe){'OK'}else{'..'}), $(if($pwshExe){$pwshExe}else{'(not yet installed)'}))

        # ---- Workdir -------------------------------------
        Set-Status 'Workdir' 5
        if (-not (Test-Path $opts.WorkDir)) {
            if ($DRY) {
                Write-Log "  [DRY] crearia dir: $($opts.WorkDir)"
            } else {
                try {
                    New-Item -ItemType Directory -Path $opts.WorkDir -Force | Out-Null
                    Write-Log "  [OK] created: $($opts.WorkDir)"
                } catch {
                    Write-Log "  [!!] could not create, fallback to Documents"
                    $opts.WorkDir = Join-Path $env:USERPROFILE 'Documents'
                }
            }
        } else { Write-Log "  [OK] dir exists" }

        # ---- Execution policy ----------------------------
        if ($opts.Policy) {
            Set-Status 'Policy' 8
            try {
                # INSTALAR.bat lanza con -ExecutionPolicy Bypass (scope Process), asi que
                # Get-ExecutionPolicy sin scope siempre dice Bypass. Lo que vera una
                # terminal nueva es la combinacion CurrentUser/LocalMachine (+ GPO).
                $gpo = @('MachinePolicy','UserPolicy') | ForEach-Object { Get-ExecutionPolicy -Scope $_ } |
                       Where-Object { $_ -ne 'Undefined' } | Select-Object -First 1
                $eff = Get-ExecutionPolicy -Scope CurrentUser
                if ($eff -eq 'Undefined') { $eff = Get-ExecutionPolicy -Scope LocalMachine }
                if ($gpo) {
                    Write-Log "  [..] policy fijada por GPO: $gpo (no se cambia)"
                } elseif ($eff -in @('Restricted','AllSigned','Undefined')) {
                    if ($DRY) {
                        Write-Log "  [DRY] policy CurrentUser -> RemoteSigned (actual: $eff)"
                    } else {
                        # Con Bypass en el scope Process (INSTALAR.bat) PowerShell guarda el
                        # valor pero lanza "overridden by a policy defined at a more specific
                        # scope": lo que cuenta es releer CurrentUser despues.
                        try { Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop } catch {}
                        if ((Get-ExecutionPolicy -Scope CurrentUser) -eq 'RemoteSigned') {
                            Write-Log "  [OK] policy CurrentUser -> RemoteSigned"
                        } else {
                            Write-Log "  [!!] no se pudo fijar CurrentUser -> RemoteSigned (directiva del equipo?)"
                            $script:failures += 'policy'
                        }
                    }
                } else {
                    Write-Log "  [OK] policy already $eff"
                }
            } catch { Write-Log "  [!!] policy: $($_.Exception.Message)" }
        }

        # ---- PSGallery prep ------------------------------
        Set-Status 'PSGallery' 12
        try {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                      Where-Object Version -ge '2.8.5.201')) {
                if ($DRY) {
                    Write-Log "  [DRY] instalaria NuGet provider >= 2.8.5.201"
                } else {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
                    Write-Log "  [OK] NuGet provider installed"
                }
            } else { Write-Log "  [OK] NuGet provider" }

            if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
                if ($DRY) {
                    Write-Log "  [DRY] PSGallery -> Trusted"
                } else {
                    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                    Write-Log "  [OK] PSGallery -> Trusted"
                }
            } else { Write-Log "  [OK] PSGallery trusted" }
        } catch { Write-Log "  [!!] gallery: $($_.Exception.Message)" }

        # ---- Winget packages (SECUENCIAL + retry) --------
        # Antes iban en paralelo: los instaladores MSI chocan entre si
        # (ERROR_INSTALL_ALREADY_RUNNING 1618) y fallan aleatoriamente.
        # Secuencial con 1 retry es mas lento pero fiable.
        Set-Status 'Packages' 18

        $pkgs = @()
        if ($opts.Pwsh -and -not $pwshExe) {
            $pkgs += @{ Id='Microsoft.PowerShell';        Name='PowerShell 7' }
        } elseif ($opts.Pwsh) {
            Write-Log "  [OK] PowerShell 7 already installed"
        }
        function Test-Optional {
            param([string]$Cmd, [string[]]$Paths)
            if ($Cmd -and (Get-Command $Cmd -ErrorAction SilentlyContinue)) { return $true }
            foreach ($p in $Paths) { if ($p -and (Test-Path $p)) { return $true } }
            return $false
        }
        function Test-FontInstalled {
            param([string]$Pattern)
            foreach ($hive in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                              'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
                if (Test-Path $hive) {
                    $names = (Get-ItemProperty $hive).PSObject.Properties |
                             Where-Object { $_.Name -notlike 'PS*' } |
                             Select-Object -ExpandProperty Name
                    if ($names -match $Pattern) { return $true }
                }
            }
            return $false
        }
        if ($opts.Git) {
            if (Test-Optional 'git' @("$env:ProgramFiles\Git\cmd\git.exe","$env:ProgramFiles\Git\bin\git.exe")) {
                Write-Log "  [OK] Git already installed"
            } else { $pkgs += @{ Id='Git.Git'; Name='Git' } }
        }
        if ($opts.WT) {
            $wtPath = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
            if ($wtPath) {
                Write-Log "  [OK] Windows Terminal already installed"
            } else { $pkgs += @{ Id='Microsoft.WindowsTerminal'; Name='Windows Terminal' } }
        }
        if ($opts.Font) {
            if (Test-FontInstalled '(?i)JetBrainsMono.*(Nerd\s*Font|\bN[FL][MP]?\b)') {
                Write-Log "  [OK] JetBrainsMono Nerd Font already installed"
            } else { $pkgs += @{ Id='DEVCOM.JetBrainsMonoNerdFont'; Name='JetBrainsMono Nerd Font' } }
        }
        if ($opts.OMP) {
            if (Test-Optional 'oh-my-posh' @("$env:LOCALAPPDATA\Programs\oh-my-posh\bin\oh-my-posh.exe",
                                              "$env:LOCALAPPDATA\Microsoft\WindowsApps\oh-my-posh.exe")) {
                Write-Log "  [OK] oh-my-posh already installed"
            } else { $pkgs += @{ Id='JanDeDobbeleer.OhMyPosh'; Name='oh-my-posh' } }
        }

        if ($opts.VSCode) {
            if (Test-Optional 'code' @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
                                        "$env:ProgramFiles\Microsoft VS Code\Code.exe")) {
                Write-Log "  [OK] VS Code already installed"
            } else { $pkgs += @{ Id='Microsoft.VisualStudioCode'; Name='Visual Studio Code' } }
        }
        if ($opts.Neovim) {
            if (Test-Optional 'nvim' @("$env:ProgramFiles\Neovim\bin\nvim.exe")) {
                Write-Log "  [OK] Neovim already installed"
            } else { $pkgs += @{ Id='Neovim.Neovim'; Name='Neovim' } }
        }
        if ($opts.SevenZip) {
            if (Test-Optional $null @("$env:ProgramFiles\7-Zip\7z.exe")) {
                Write-Log "  [OK] 7-Zip already installed"
            } else { $pkgs += @{ Id='7zip.7zip'; Name='7-Zip' } }
        }
        if ($opts.GitHubDesktop) {
            if (Test-Optional $null @("$env:LOCALAPPDATA\GitHubDesktop\GitHubDesktop.exe")) {
                Write-Log "  [OK] GitHub Desktop already installed"
            } else { $pkgs += @{ Id='GitHub.GitHubDesktop'; Name='GitHub Desktop' } }
        }
        if ($opts.ClaudeCode) {
            if (Test-Optional 'claude' @("$env:LOCALAPPDATA\Programs\claude-code\claude.exe")) {
                Write-Log "  [OK] Claude Code already installed"
            } else { $pkgs += @{ Id='Anthropic.ClaudeCode'; Name='Claude Code' } }
        }
        if ($opts.Codex) {
            if (Test-Optional 'codex' @()) {
                Write-Log "  [OK] Codex CLI already installed"
            } else { $pkgs += @{ Id='OpenAI.Codex'; Name='Codex CLI' } }
        }
        if ($opts.Antigravity) {
            if (Test-Optional 'antigravity' @("$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe")) {
                Write-Log "  [OK] Antigravity already installed"
            } else { $pkgs += @{ Id='Google.Antigravity'; Name='Antigravity' } }
        }
        if ($opts.Node) {
            # Node.js: lo necesitan los servidores MCP via npx (Claude Code Setup Guide)
            if (Test-Optional 'node' @("$env:ProgramFiles\nodejs\node.exe")) {
                Write-Log "  [OK] Node.js already installed"
            } else { $pkgs += @{ Id='OpenJS.NodeJS.LTS'; Name='Node.js LTS' } }
        }

        if ($hasWinget -and $pkgs.Count -gt 0 -and $DRY) {
            foreach ($p in $pkgs) {
                Write-Log "  [DRY] winget install --id $($p.Id) -e --silent   ($($p.Name))"
            }
        } elseif ($hasWinget -and $pkgs.Count -gt 0) {
            Write-Log "  [..] installing $($pkgs.Count) packages (sequential, reliable)..."

            # Snapshot desktop shortcuts so we can clean up new ones afterwards
            $desktopDirs = @([Environment]::GetFolderPath('Desktop'),
                             [Environment]::GetFolderPath('CommonDesktopDirectory')) |
                           Where-Object { $_ -and (Test-Path $_) }
            $desktopBefore = @{}
            foreach ($d in $desktopDirs) {
                $desktopBefore[$d] = @(Get-ChildItem $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
                                       Select-Object -ExpandProperty Name)
            }

            # Show Pause button while installs run
            if (-not $sync.NoGui) {
                $sync.Window.Dispatcher.Invoke([action]{
                    $sync.PauseBtn.Visibility = [System.Windows.Visibility]::Visible
                    $sync.PauseBtn.Content = 'Pause'
                })
            }

            # winget exit codes ok: 0; -1978335189 = no upgrade; -1978335212 = no applicable
            $okCodes = @(0, -1978335189, -1978335212)
            # retry-ables: 1618 / 0x80070652 = otro instalador MSI en curso
            $busyCodes = @(1618, -2147023278)

            $total = $pkgs.Count
            $idx = 0
            foreach ($p in $pkgs) {
                $idx++
                $basePct = 18 + [int](37 * ($idx - 1) / $total)
                Set-Status "Packages ($idx/$total): $($p.Name)" $basePct
                Write-Log "  [..] installing $($p.Name)..."

                $wingetArgs = @(
                    'install','--id',$p.Id,'-e','--silent',
                    '--source','winget',
                    '--accept-package-agreements','--accept-source-agreements',
                    '--disable-interactivity'
                )

                $code = $null
                foreach ($attempt in 1,2) {
                    $proc = Start-Process winget -ArgumentList $wingetArgs -WindowStyle Hidden -PassThru
                    if (-not $sync.NoGui) {
                        $sync.Window.Dispatcher.Invoke([action]{ [void]$sync.ActiveProcs.Add($proc) })
                    }
                    while (-not $proc.HasExited) {
                        Start-Sleep -Milliseconds 300
                        if ($sync.Paused) { Set-Status "Packages paused ($idx/$total)" $basePct }
                    }
                    if (-not $sync.NoGui) {
                        $sync.Window.Dispatcher.Invoke([action]{ $sync.ActiveProcs.Clear() })
                    }
                    $code = $proc.ExitCode
                    if ($okCodes -contains $code) { break }
                    if (($busyCodes -contains $code) -and $attempt -eq 1) {
                        Write-Log ("  [..] {0}: otro instalador ocupado (0x{1:X8}), retry en 15s..." -f $p.Name, $code)
                        Start-Sleep -Seconds 15
                        continue
                    }
                    break
                }

                if ($okCodes -contains $code) {
                    Write-Log ("  [OK] {0}" -f $p.Name)
                } else {
                    $hint = ''
                    if ($code -eq -2147023838) { $hint = ' - servicio de Windows deshabilitado (Windows Installer): se probara la version portable' }
                    elseif (-not $isAdmin)     { $hint = ' - sin permisos de admin para un instalador de equipo: se probara la version portable si existe' }
                    Write-Log ("  [!!] {0} (exit 0x{1:X8}){2}" -f $p.Name, $code, $hint)
                    $script:failures += $p.Name
                }
            }

            if (-not $sync.NoGui) {
                $sync.Window.Dispatcher.Invoke([action]{
                    $sync.PauseBtn.Visibility = [System.Windows.Visibility]::Collapsed
                    $sync.ActiveProcs.Clear()
                    $sync.Paused = $false
                })
            }

            # Cleanup desktop shortcuts created by installers
            foreach ($d in $desktopDirs) {
                $now = Get-ChildItem $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue
                foreach ($lnk in $now) {
                    if ($desktopBefore[$d] -notcontains $lnk.Name) {
                        try {
                            Remove-Item $lnk.FullName -Force -ErrorAction Stop
                            Write-Log "  [OK] removed desktop shortcut: $($lnk.Name)"
                        } catch {}
                    }
                }
            }
        } elseif (-not $hasWinget -and $pkgs.Count) {
            Write-Log "  [!!] winget missing, skipping all packages"
        }

        # ---- Font fallback: descarga directa si winget no la dejo instalada ---
        # En equipos nuevos winget a veces falla con la fuente (source desactualizado,
        # scope maquina sin admin...). Plan B: zip oficial de nerd-fonts e instalacion
        # por usuario (LOCALAPPDATA\...\Fonts + HKCU), sin necesidad de admin.
        if ($opts.Font -and -not $DRY -and
            -not (Test-FontInstalled '(?i)JetBrainsMono.*(Nerd\s*Font|\bN[FL][MP]?\b)')) {
            Set-Status 'Font (direct download)' 56
            Write-Log "  [..] Nerd Font aun no instalada, fallback: descarga directa de GitHub..."
            try {
                $fontTmp = Join-Path $env:TEMP "vorterm-nerdfont-$PID"
                $zipPath = Join-Path $fontTmp 'JetBrainsMono.zip'
                New-Item -ItemType Directory -Path $fontTmp -Force | Out-Null
                $url = 'https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
                Expand-Archive -Path $zipPath -DestinationPath $fontTmp -Force

                $userFonts = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
                New-Item -ItemType Directory -Path $userFonts -Force | Out-Null
                $reg = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
                if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }

                Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                $installed = 0
                foreach ($ttf in (Get-ChildItem $fontTmp -Filter '*.ttf' -File)) {
                    $dest = Join-Path $userFonts $ttf.Name
                    Copy-Item $ttf.FullName $dest -Force
                    # Nombre de familia real del TTF para el valor de registro
                    $fam = $null
                    try {
                        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
                        $pfc.AddFontFile($dest)
                        $fam = $pfc.Families[0].Name
                        $pfc.Dispose()
                    } catch {}
                    if (-not $fam) { $fam = [IO.Path]::GetFileNameWithoutExtension($ttf.Name) }
                    New-ItemProperty -Path $reg -Name "$fam (TrueType)" -Value $dest `
                                     -PropertyType String -Force | Out-Null
                    $installed++
                }
                Remove-Item $fontTmp -Recurse -Force -ErrorAction SilentlyContinue
                if ($installed -gt 0) {
                    # Notificar cambio de fuentes a las apps (WM_FONTCHANGE)
                    try {
                        Add-Type -Namespace Vorterm -Name FontMsg -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
                        $r = [UIntPtr]::Zero
                        [void][Vorterm.FontMsg]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)
                    } catch {}
                    Write-Log "  [OK] Nerd Font instalada por usuario ($installed ficheros TTF)"
                } else {
                    Write-Log "  [!!] Font fallback: zip sin TTFs"
                    $script:failures += 'font'
                }
            } catch {
                Write-Log "  [!!] Font fallback: $($_.Exception.Message)"
                $script:failures += 'font'
            }
        }

        # ---- Plan B sin MSI ni admin: PowerShell 7 y oh-my-posh portables ----
        # winget instala ambos con MSI: falla con Windows Installer deshabilitado
        # (0x80070422, equipos endurecidos) o sin admin. Binarios oficiales en el
        # perfil del usuario + PATH de usuario. Las rutas son las que ya buscan
        # Find-Pwsh y el perfil, asi que el resto del instalador los encuentra.
        function Add-UserPath {
            param([string]$Dir)
            $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (@($cur -split ';') -notcontains $Dir) {
                $newPath = if ($cur) { "$cur;$Dir" } else { $Dir }
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            }
            if (@($env:Path -split ';') -notcontains $Dir) { $env:Path += ";$Dir" }
        }
        $cpuArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        $ghHeaders = @{ 'User-Agent' = 'Vorterm' }

        if ($opts.Pwsh -and -not $DRY -and -not (Find-Pwsh)) {
            Set-Status 'PowerShell 7 (portable)' 56
            Write-Log "  [..] PowerShell 7 no quedo instalado, plan B: zip portable oficial (sin admin)..."
            try {
                $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers $ghHeaders -UseBasicParsing
                $asset = @($rel.assets) | Where-Object { $_.name -match "^PowerShell-[\d.]+-win-$cpuArch\.zip$" } | Select-Object -First 1
                if (-not $asset) { throw "no hay zip win-$cpuArch en $($rel.tag_name)" }
                $pzip = Join-Path $env:TEMP "vorterm-pwsh-$PID.zip"
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $pzip -UseBasicParsing
                $hashAsset = @($rel.assets) | Where-Object { $_.name -eq 'hashes.sha256' } | Select-Object -First 1
                $want = $null
                if ($hashAsset) {
                    # hashes.sha256 viene en UTF-16 con BOM: fichero + Select-String (detecta BOM)
                    $sumFile = Join-Path $env:TEMP "vorterm-pwsh-$PID.sha256"
                    Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $sumFile -UseBasicParsing
                    $line = Select-String -LiteralPath $sumFile -Pattern $asset.name -SimpleMatch | Select-Object -First 1
                    Remove-Item $sumFile -Force -ErrorAction SilentlyContinue
                    if ($line) { $want = ($line.Line.Trim() -split '\s+')[0].ToUpperInvariant() }
                }
                if ($want) {
                    if ($want -ne (Get-FileHash -LiteralPath $pzip -Algorithm SHA256).Hash) { Remove-Item $pzip -Force; throw "SHA256 no coincide ($($asset.name))" }
                    Write-Log "  [OK] SHA256 verificado: $($asset.name)"
                } else {
                    Write-Log "  [..] sin hash publicado para $($asset.name): no verificado"
                }
                $pdir = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7'
                New-Item -ItemType Directory -Path $pdir -Force | Out-Null
                Expand-Archive -Path $pzip -DestinationPath $pdir -Force
                Remove-Item $pzip -Force -ErrorAction SilentlyContinue
                Add-UserPath $pdir
                $pwshExe = Find-Pwsh
                if (-not $pwshExe) { throw "pwsh.exe no aparece en $pdir" }
                Write-Log "  [OK] PowerShell $($rel.tag_name) portable: $pwshExe (PATH de usuario)"
                $script:failures = @($script:failures | Where-Object { $_ -ne 'PowerShell 7' })
            } catch {
                Write-Log "  [!!] PowerShell 7 portable: $($_.Exception.Message)"
            }
        }

        if ($opts.OMP -and -not $DRY -and
            -not (Test-Optional 'oh-my-posh' @("$env:LOCALAPPDATA\Programs\oh-my-posh\bin\oh-my-posh.exe",
                                               "$env:LOCALAPPDATA\Microsoft\WindowsApps\oh-my-posh.exe"))) {
            Set-Status 'oh-my-posh (portable)' 57
            Write-Log "  [..] oh-my-posh no quedo instalado, plan B: ejecutable oficial (sin admin)..."
            try {
                $oarch = if ($cpuArch -eq 'arm64') { 'arm64' } else { 'amd64' }
                $oname = "posh-windows-$oarch.exe"
                $odir  = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'
                $oexe  = Join-Path $odir 'oh-my-posh.exe'
                $otmp  = Join-Path $env:TEMP "vorterm-$oname"
                Invoke-WebRequest -Uri "https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/$oname" -OutFile $otmp -UseBasicParsing
                if ((Get-Item $otmp).Length -lt 1mb) { throw 'descarga incompleta' }
                $owant = $null
                try {
                    $osumFile = "$otmp.checksums.txt"
                    Invoke-WebRequest -Uri 'https://github.com/JanDeDobbeleer/oh-my-posh/releases/latest/download/checksums.txt' -OutFile $osumFile -UseBasicParsing
                    $oline = Select-String -LiteralPath $osumFile -Pattern $oname -SimpleMatch | Select-Object -First 1
                    Remove-Item $osumFile -Force -ErrorAction SilentlyContinue
                    if ($oline) { $owant = ($oline.Line.Trim() -split '\s+')[0].ToUpperInvariant() }
                } catch {}
                if ($owant -match '^[0-9A-F]{64}$') {
                    if ($owant -ne (Get-FileHash -LiteralPath $otmp -Algorithm SHA256).Hash) { Remove-Item $otmp -Force; throw "SHA256 no coincide ($oname)" }
                    Write-Log "  [OK] SHA256 verificado: $oname"
                } else {
                    Write-Log "  [..] sin hash publicado para ${oname}: no verificado"
                }
                New-Item -ItemType Directory -Path $odir -Force | Out-Null
                Move-Item -LiteralPath $otmp -Destination $oexe -Force
                Add-UserPath $odir
                Write-Log "  [OK] oh-my-posh portable: $oexe (PATH de usuario)"
                $script:failures = @($script:failures | Where-Object { $_ -ne 'oh-my-posh' })
            } catch {
                Write-Log "  [!!] oh-my-posh portable: $($_.Exception.Message)"
            }
        }

        # ---- WSL (separate from winget, uses wsl --install) ---
        if ($opts.WSL) {
            Set-Status 'WSL' 58
            try {
                $wslList = & wsl.exe --list --quiet 2>$null
                $hasDistro = ($LASTEXITCODE -eq 0) -and
                             ($wslList | Where-Object { $_ -and $_.Trim() } | Measure-Object).Count -gt 0
            } catch { $hasDistro = $false }

            if ($hasDistro) {
                Write-Log "  [OK] WSL already installed with distro"
            } elseif ($DRY) {
                Write-Log "  [DRY] wsl --install --no-launch"
            } else {
                Write-Log "  [..] installing WSL + default distro (Ubuntu, no-launch)..."
                try {
                    $wslProc = Start-Process wsl.exe -ArgumentList '--install','--no-launch' `
                               -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($wslProc.ExitCode -eq 0) {
                        Write-Log "  [OK] WSL installed. Reboot may be required to finish setup."
                    } else {
                        Write-Log "  [!!] WSL install exit 0x$('{0:X8}' -f $wslProc.ExitCode)"
                        $script:failures += 'WSL'
                    }
                } catch {
                    Write-Log "  [!!] WSL: $($_.Exception.Message)"
                    $script:failures += 'WSL'
                }
            }
        }

        # Refresh PATH + re-locate pwsh
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [System.Environment]::GetEnvironmentVariable('Path','User')
        if (-not $pwshExe) { $pwshExe = Find-Pwsh }

        # ---- PS modules ----------------------------------
        Set-Status 'Modules' 60

        # Save-Module to PS7 path explicitly. Install-Module under PS5.1 host
        # would land in Documents\WindowsPowerShell\Modules which PS7 ignores.
        # La ruta de usuario la dice el propio pwsh (OneDrive Known Folder Move).
        $ps7Mod = $null
        if ($pwshExe) {
            try {
                $ps7Mod = (& $pwshExe -NoProfile -NonInteractive -Command '($env:PSModulePath -split [IO.Path]::PathSeparator)[0]' 2>$null |
                           Select-Object -First 1).Trim()
            } catch {}
        }
        if (-not $ps7Mod) {
            $docsDir = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
            if (-not $docsDir) { $docsDir = Join-Path $env:USERPROFILE 'Documents' }
            $ps7Mod = Join-Path $docsDir 'PowerShell\Modules'
        }

        function Get-PwshModuleVersion {
            param([string]$Name)
            if (-not $pwshExe) { return $null }
            try {
                $v = & $pwshExe -NoProfile -NonInteractive -Command "(Get-Module -ListAvailable -Name '$Name' | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()" 2>$null |
                     Select-Object -First 1
                if ($v) { return [version]($v.Trim()) }
            } catch {}
            return $null
        }

        # $Version = version minima. Si pwsh ya ve una igual o mayor (p.ej. la
        # PSReadLine 2.4.x que trae PowerShell 7.5+) no se instala nada: nunca se
        # degrada un modulo.
        function Install-PSMod {
            param([string]$Name, [string]$Version)

            try {
                $have = Get-PwshModuleVersion $Name
                if ($have -and (-not $Version -or $have -ge [version]$Version)) {
                    Write-Log "  [OK] $Name $have already present"
                    return
                }
                $modDir = Join-Path $ps7Mod $Name
                $hasManifest = $false
                if (-not $pwshExe -and (Test-Path $modDir)) {
                    $hasManifest = [bool](Get-ChildItem $modDir -Recurse -Filter "$Name.psd1" -ErrorAction SilentlyContinue | Select-Object -First 1)
                }
                if ($hasManifest) {
                    Write-Log "  [OK] $Name already present"
                    return
                }
                if ($DRY) {
                    Write-Log "  [DRY] Save-Module $Name $Version -> $ps7Mod"
                    return
                }
                if (-not (Test-Path $ps7Mod)) { New-Item -ItemType Directory -Path $ps7Mod -Force | Out-Null }
                if ((Test-Path $modDir) -and -not $have) {
                    Write-Log "  [..] $Name dir empty/corrupt, re-installing"
                    Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
                }

                Write-Log ("  [..] {0} {1} -> {2}" -f $Name,$Version,$ps7Mod)
                $verArg = if ($Version) { "-RequiredVersion '$Version'" } else { '' }
                $cmd = "Save-Module -Name '$Name' -Path '$ps7Mod' -Force -ErrorAction Stop $verArg"
                if ($pwshExe) {
                    $out = & $pwshExe -NoProfile -Command $cmd 2>&1 | Out-String
                    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
                        throw "pwsh Save-Module failed: $out"
                    }
                } else {
                    $saveArgs = @{
                        Name        = $Name
                        Path        = $ps7Mod
                        Force       = $true
                        ErrorAction = 'Stop'
                    }
                    if ($Version) { $saveArgs.RequiredVersion = $Version }
                    Save-Module @saveArgs
                }
                Write-Log "  [OK] $Name installed"
            } catch {
                Write-Log "  [!!] ${Name}: $($_.Exception.Message)"
                $script:failures += $Name
            }
        }

        $modIdx = 0
        $modList = @()
        if ($opts.PSRL)    { $modList += ,@{ N='PSReadLine';     V='2.3.6' } }
        if ($opts.Icons)   { $modList += ,@{ N='Terminal-Icons'; V=$null } }
        if ($opts.PoshGit) { $modList += ,@{ N='posh-git';       V=$null } }
        foreach ($m in $modList) {
            $modIdx++
            Set-Status "Modules ($modIdx/$($modList.Count))" (60 + [int](12 * $modIdx / [Math]::Max(1,$modList.Count)))
            Install-PSMod -Name $m.N -Version $m.V
        }

        # ---- Detect actual Nerd Font name ----------------
        # Windows Terminal usa DirectWrite. JetBrainsMono Nerd Font v3 tiene 2 nombres
        # en la tabla "name" del TTF:
        #   - name ID 1  (GDI family):           "JetBrainsMono NFM" (lo que enumera GDI+)
        #   - name ID 16 (typographic / DWrite): "JetBrainsMono Nerd Font Mono" (lo que WT espera)
        # Si escribimos el GDI family, WT muestra warning "no se puede encontrar la fuente"
        # y cae al fallback. Solucion: mapear GDI family -> typographic family.
        Set-Status 'Font detect' 74
        function Get-InstalledNerdFont {
            try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch {}
            $gdi = @()
            try {
                $gdi = [System.Drawing.Text.InstalledFontCollection]::new().Families.Name
            } catch {
                Write-Log "  [!!] GDI+ font enum failed: $($_.Exception.Message)"
            }

            # Mapping GDI family -> typographic (DirectWrite) family.
            # Nerd Font v3 convention: NFM=Mono, NFP=Propo, NF=full.
            # Prioridad NF (familia completa) primero: es la cara que usa el perfil
            # de referencia "PowerShell Main" (JetBrainsMono Nerd Font).
            $gdiToTypo = [ordered]@{
                'JetBrainsMono NF'     = 'JetBrainsMono Nerd Font'
                'JetBrainsMonoNL NF'   = 'JetBrainsMonoNL Nerd Font'
                'JetBrainsMono NFM'    = 'JetBrainsMono Nerd Font Mono'
                'JetBrainsMonoNL NFM'  = 'JetBrainsMonoNL Nerd Font Mono'
                'JetBrainsMono NFP'    = 'JetBrainsMono Nerd Font Propo'
                'JetBrainsMonoNL NFP'  = 'JetBrainsMonoNL Nerd Font Propo'
                'CaskaydiaCove NF'     = 'CaskaydiaCove Nerd Font'
                'CaskaydiaCove NFM'    = 'CaskaydiaCove Nerd Font Mono'
                'CaskaydiaMono NF'     = 'CaskaydiaMono Nerd Font'
                'FiraCode NF'          = 'FiraCode Nerd Font'
                'FiraCode NFM'         = 'FiraCode Nerd Font Mono'
                'Hack NF'              = 'Hack Nerd Font'
                'Hack NFM'             = 'Hack Nerd Font Mono'
            }

            # Prioridad: NF > Mono > Propo. Iterar mapping en orden.
            foreach ($gdiName in $gdiToTypo.Keys) {
                if ($gdi -contains $gdiName) {
                    $typo = $gdiToTypo[$gdiName]
                    Write-Log "  [OK] GDI '$gdiName' -> DWrite typographic '$typo'"
                    return $typo
                }
            }

            # Algunas instalaciones (Nerd Font v2 o variantes especiales) ya exponen
            # el typographic name como GDI family. Probar match directo.
            $directPriority = @(
                'JetBrainsMono Nerd Font',
                'JetBrainsMonoNL Nerd Font',
                'JetBrainsMono Nerd Font Mono',
                'JetBrainsMonoNL Nerd Font Mono',
                'JetBrainsMono Nerd Font Propo',
                'CaskaydiaCove Nerd Font',
                'FiraCode Nerd Font',
                'Hack Nerd Font'
            )
            foreach ($cand in $directPriority) {
                if ($gdi -contains $cand) { return $cand }
            }

            # Fallback generico: cualquier "Nerd Font Mono" en GDI+
            $hit = $gdi | Where-Object { $_ -match '(?i)Nerd\s+Font\s+Mono$' } | Select-Object -First 1
            if ($hit) { return $hit }
            $hit = $gdi | Where-Object { $_ -match '(?i)Nerd\s+Font' } | Select-Object -First 1
            if ($hit) { return $hit }

            Write-Log "  [!!] No Nerd Font detected. Falling back to default DWrite name."
            return 'JetBrainsMono Nerd Font'
        }
        $nerdFontFace = Get-InstalledNerdFont
        Write-Log "  [OK] detected font face (DWrite typographic): '$nerdFontFace'"

        # ---- Prompt theme (Mainthema, local, sin internet) ----
        Set-Status 'Theme' 76
        $userThemes = Join-Path $env:USERPROFILE '.poshthemes'
        $userTheme  = Join-Path $userThemes $opts.ThemeFile
        try {
            $srcContent = if ($opts.ThemeSrc -and (Test-Path $opts.ThemeSrc)) {
                Get-Content $opts.ThemeSrc -Raw -Encoding UTF8
            } else {
                $opts.ThemeJson
            }
            $needWrite = $true
            if (Test-Path $userTheme) {
                $cur = Get-Content $userTheme -Raw -Encoding UTF8
                if ($cur -eq $srcContent) {
                    Write-Log "  [OK] theme already at $userTheme"
                    $needWrite = $false
                }
            }
            if ($needWrite -and $DRY) {
                Write-Log "  [DRY] escribiria theme: $userTheme"
            } elseif ($needWrite) {
                if (-not (Test-Path $userThemes)) {
                    New-Item -ItemType Directory -Path $userThemes -Force | Out-Null
                }
                if (Test-Path $userTheme) {
                    $bk = "$userTheme.bak-$(Get-Date -Format yyyyMMddHHmmss)"
                    Copy-Item $userTheme $bk -Force
                    Write-Log "  [..] backup theme: $bk"
                }
                [System.IO.File]::WriteAllText($userTheme, $srcContent, (New-Object System.Text.UTF8Encoding $false))
                Write-Log "  [OK] theme written: $userTheme"
            }
        } catch {
            Write-Log "  [!!] theme: $($_.Exception.Message)"
            $script:failures += 'theme'
        }

        # Setear POSH_THEMES_PATH user env si esta vacio
        if (-not [Environment]::GetEnvironmentVariable('POSH_THEMES_PATH','User')) {
            if ($DRY) {
                Write-Log "  [DRY] POSH_THEMES_PATH (User) -> $userThemes"
            } else {
                [Environment]::SetEnvironmentVariable('POSH_THEMES_PATH', $userThemes, 'User')
                Write-Log "  [OK] POSH_THEMES_PATH (User) -> $userThemes"
            }
        }

        # ---- PowerShell profile --------------------------
        if ($opts.WriteProfile) {
            Set-Status 'Profile' 80

            # Ruta REAL del perfil. Con OneDrive "Known Folder Move" Documents vive
            # en OneDrive\Documentos: si escribimos en USERPROFILE\Documents, pwsh
            # carga OTRO perfil (viejo) y el tema nunca se aplica. La verdad la
            # tiene $PROFILE de cada engine; fallback: carpeta Documents real.
            $realDocs = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
            if (-not $realDocs) { $realDocs = Join-Path $env:USERPROFILE 'Documents' }

            $ps7Path = $null
            if ($pwshExe) {
                try {
                    $ps7Path = (& $pwshExe -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserCurrentHost' 2>$null |
                                Select-Object -First 1).Trim()
                } catch {}
            }
            if (-not $ps7Path) { $ps7Path = Join-Path $realDocs 'PowerShell\Microsoft.PowerShell_profile.ps1' }
            $ps7Dir = Split-Path $ps7Path

            $ps5Path = $null
            try {
                $ps5Path = (& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                            -NoProfile -NonInteractive -Command '$PROFILE.CurrentUserCurrentHost' 2>$null |
                            Select-Object -First 1).Trim()
            } catch {}
            if (-not $ps5Path) { $ps5Path = Join-Path $realDocs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1' }
            $ps5Dir = Split-Path $ps5Path
            Write-Log "  [..] perfil PS7 real: $ps7Path"
            Write-Log "  [..] perfil PS5 real: $ps5Path"

            # Perfiles obsoletos en la ubicacion NO activa (p.ej. Documents local
            # cuando OneDrive manda, o viceversa): neutralizar para que no pisen
            # el tema ni suelten errores viejos al arrancar.
            $staleCandidates = @(
                (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
                (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
                (Join-Path $realDocs 'PowerShell\Microsoft.PowerShell_profile.ps1'),
                (Join-Path $realDocs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
            ) | Sort-Object -Unique | Where-Object { $_ -ne $ps7Path -and $_ -ne $ps5Path -and (Test-Path $_) }
            foreach ($stale in $staleCandidates) {
                if ($DRY) { Write-Log "  [DRY] perfil obsoleto -> renombrar: $stale"; continue }
                try {
                    Move-Item $stale "$stale.vorterm-stale-$(Get-Date -Format yyyyMMddHHmmss)" -Force
                    Write-Log "  [OK] perfil obsoleto apartado: $stale"
                } catch {
                    Write-Log "  [!!] no se pudo apartar perfil obsoleto: $stale"
                }
            }

            $escapedPath  = $opts.WorkDir -replace "'", "''"
            $themeLeaf    = $opts.ThemeFile

            # Multi-pane: ventanas de Windows Terminal con 2/3/4 paneles del perfil
            # oculto "Vorterm Mosaic" (negro puro, sin imagen de fondo). Cada panel
            # registra su PID para que "close N" cierre un panel concreto.
            $multiPaneBlock = ''
            if ($opts.MultiPane) {
                $multiPaneBlock = @'
# --- Multi-pane: m2 / m3 / m4, close N, /commands -------------
function Start-VortermMosaic {
    param([int]$N, [switch]$Rows, [switch]$Claude)
    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { Write-Warning 'Windows Terminal (wt.exe) not found'; return }
    $dir = Join-Path $env:TEMP 'vorterm-mpane'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $g = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $cl = ''; if ($Claude) { $cl = ' -Claude' }
    $shell = 'pwsh'; if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { $shell = 'powershell' }
    $p = '-p {7628d9b6-6917-4040-b9a2-986f96f1361d}'
    $pane = { param($i) "$p --title `"Main $i`" $shell -NoLogo -NoExit -Command Initialize-VortermPane $g $i$cl" }
    if ($N -eq 4 -and -not $Rows) {
        $a = "new-tab $(& $pane 1) ; split-pane -V -s 0.5 $(& $pane 2) ; move-focus left ; split-pane -H -s 0.5 $(& $pane 3) ; move-focus right ; split-pane -H -s 0.5 $(& $pane 4)"
    } else {
        $d = '-V'; if ($Rows) { $d = '-H' }
        $a = "new-tab $(& $pane 1)"
        for ($i = 2; $i -le $N; $i++) {
            $s = ([double]($N - $i + 1) / ($N - $i + 2)).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            $a += " ; split-pane $d -s $s $(& $pane $i)"
        }
    }
    Start-Process wt.exe -ArgumentList "-w new --maximized $a ; focus-pane -t 0"
}
function Initialize-VortermPane {
    param([string]$Group, [int]$Index, [switch]$Claude)
    $env:VORTERM_MGROUP = $Group; $env:VORTERM_MPANE = $Index
    Set-Content -Path (Join-Path $env:TEMP "vorterm-mpane\$Group-$Index") -Value $PID
    if ($Claude) {
        if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Warning 'claude not found in PATH' }
    }
}
function m2 { param([switch]$Rows, [switch]$Claude) Start-VortermMosaic 2 -Rows:$Rows -Claude:$Claude }
function m3 { param([switch]$Rows, [switch]$Claude) Start-VortermMosaic 3 -Rows:$Rows -Claude:$Claude }
function m4 { param([switch]$Rows, [switch]$Claude) Start-VortermMosaic 4 -Rows:$Rows -Claude:$Claude }
function close {
    param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][int[]]$Pane)
    if (-not $env:VORTERM_MGROUP) { Write-Warning 'Only works in windows opened with m2, m3 or m4'; return }
    foreach ($i in ($Pane | Sort-Object { $_ -eq [int]$env:VORTERM_MPANE })) {
        $f = Join-Path $env:TEMP "vorterm-mpane\$($env:VORTERM_MGROUP)-$i"
        $id = 0
        if (Test-Path $f) { $id = [int](Get-Content $f | Select-Object -First 1) }
        $proc = $null
        if ($id) { $proc = Get-Process -Id $id -ErrorAction SilentlyContinue }
        if ($proc -and @('pwsh', 'powershell') -contains $proc.ProcessName) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            & taskkill.exe /T /F /PID $id | Out-Null
        } else { Write-Warning "Pane $i is not open" }
    }
}
function /commands {
    $e = [char]27
    @(
        @('m2 / m3', '2 or 3 columns'), @('m4', '2x2 grid'), @('-Rows', 'stack as rows'), @('-Claude', 'Claude Code in every pane'),
        @('close 2', 'close pane 2 (or several: close 2 3)'), @('', ''),
        @('Ctrl+Shift+3', 'split tab in 3'), @('Ctrl+Shift+W', 'close current pane'), @('Alt+arrows', 'switch pane'),
        @('Alt+Shift+arrows', 'resize'), @('Ctrl+Shift+Z', 'zoom pane'), @('Ctrl+Shift+B', 'type in all panes'), @('Alt+Shift+D', 'duplicate pane')
    ) | ForEach-Object { if ($_[0]) { "  {0,-18} $e[2m{1}$e[0m" -f $_[0], $_[1] } else { '' } }
}
'@
            }

            # Perfil unico para PS5.1 y PS7 con guards por version:
            #  - PSReadLine Prediction* solo si PSReadLine >= 2.2 (PS5.1 trae 2.0.0
            #    y "parametro no encontrado" NO se suprime con -ErrorAction).
            #  - oh-my-posh init cacheado + try/catch -> si falla, prompt fallback.
            $profileContent = @"
# Vorterm $($opts.Version) - visual / terminal config

# --- Extra PATH (developer tools when present) ----------------
`$_pathAdds = 'C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Program Files\nodejs'
if (`$env:Path -notlike "*Git\cmd*") { `$env:Path = `$env:Path + ';' + `$_pathAdds }

# --- oh-my-posh (cached init, evita spawn de oh-my-posh.exe en cada arranque) -
`$script:_ompActive = `$false
`$_ompExe = "`$env:LOCALAPPDATA\Microsoft\WindowsApps\oh-my-posh.exe"
if (-not (Test-Path `$_ompExe)) { `$_ompExe = "`$env:LOCALAPPDATA\Programs\oh-my-posh\bin\oh-my-posh.exe" }
if (Test-Path `$_ompExe) {
    try {
        `$_ompTheme = "`$env:USERPROFILE\.poshthemes\$themeLeaf"
        if (-not (Test-Path `$_ompTheme) -and `$env:POSH_THEMES_PATH) {
            `$_ompTheme = Join-Path `$env:POSH_THEMES_PATH '$themeLeaf'
        }
        `$_themeHash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes(`$_ompTheme))).Replace('-','').Substring(0,8)
        # v2: los caches v1 llevaban Set-PSReadLineOption -PredictionSource
        # HistoryAndPlugin del propio oh-my-posh init, que casca en consolas no
        # interactivas / PSReadLine sin plugin. Nombre nuevo = cache viejo fuera.
        `$_ompCache  = "`$env:LOCALAPPDATA\Vorterm\omp-init2-`$_themeHash.ps1"
        `$_cacheDir = Split-Path `$_ompCache
        if (-not (Test-Path `$_cacheDir)) { New-Item -ItemType Directory -Path `$_cacheDir -Force | Out-Null }
        `$_themeMtime = if (Test-Path `$_ompTheme) { (Get-Item `$_ompTheme).LastWriteTimeUtc.Ticks } else { 0 }
        `$_exeMtime   = (Get-Item `$_ompExe).LastWriteTimeUtc.Ticks
        `$_cacheValid = (Test-Path `$_ompCache) -and
                       ((Get-Item `$_ompCache).Length -gt 0) -and
                       ((Get-Item `$_ompCache).LastWriteTimeUtc.Ticks -gt [Math]::Max(`$_themeMtime,`$_exeMtime))
        if (-not `$_cacheValid) {
            if (Test-Path `$_ompTheme) {
                & `$_ompExe init pwsh --config `$_ompTheme | Out-File -FilePath `$_ompCache -Encoding utf8
            } else {
                & `$_ompExe init pwsh | Out-File -FilePath `$_ompCache -Encoding utf8
            }
            # Sanear: el init de OMP mete Set-PSReadLineOption (PredictionSource
            # HistoryAndPlugin...) que lanza EXCEPCION (no la traga -ErrorAction)
            # en consolas no interactivas o PSReadLine sin plugin. try/catch.
            # El perfil ya configura PSReadLine con guards por version.
            `$_c = Get-Content `$_ompCache -Raw
            `$_c = `$_c -replace '(?m)^(\s*)(Set-PSReadLineOption\b[^\r\n]*?)(\s*-ErrorAction\s+\w+)?\s*`$', '`$1try { `$2 -ErrorAction SilentlyContinue } catch {}'
            Set-Content -Path `$_ompCache -Value `$_c -Encoding utf8
        }
        if ((Get-Item `$_ompCache).Length -gt 0) {
            . `$_ompCache
            `$script:_ompActive = `$true
        }
    } catch {
        `$script:_ompActive = `$false
    }
}

# --- PSReadLine: import + config inmediato (necesario para tipear) -----------
Import-Module PSReadLine -ErrorAction SilentlyContinue
if (Get-Module PSReadLine) {
    Set-PSReadLineOption -HistorySaveStyle SaveIncrementally -ErrorAction SilentlyContinue
    Set-PSReadLineOption -MaximumHistoryCount 20000          -ErrorAction SilentlyContinue
    Set-PSReadLineOption -BellStyle None                     -ErrorAction SilentlyContinue
    Set-PSReadLineOption -EditMode Windows                   -ErrorAction SilentlyContinue

    # Prediction: solo PSReadLine >= 2.2 (PS5.1 trae 2.0.0; el error de
    # parametro desconocido NO se suprime con -ErrorAction) y solo con consola
    # real: con la salida redirigida (scripts, agentes, pwsh -Command) PSReadLine
    # lanza un error terminante que -ErrorAction tampoco suprime.
    if ((Get-Module PSReadLine).Version -ge [version]'2.2.0' -and -not [Console]::IsOutputRedirected) {
        try {
            Set-PSReadLineOption -PredictionSource History
            Set-PSReadLineOption -PredictionViewStyle ListView
        } catch {}
    }

    Set-PSReadLineKeyHandler -Key Tab               -Function MenuComplete           -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Ctrl+r            -Function ReverseSearchHistory   -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key UpArrow           -Function HistorySearchBackward  -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key DownArrow         -Function HistorySearchForward   -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Ctrl+RightArrow   -Function ForwardWord            -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow    -Function BackwardWord           -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Ctrl+Backspace    -Function BackwardKillWord       -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Ctrl+Delete       -Function KillWord               -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Home              -Function BeginningOfLine        -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key End               -Function EndOfLine              -ErrorAction SilentlyContinue
}

# --- Modulos pesados: lazy load tras el primer prompt (no bloquea arranque) --
# posh-git/Terminal-Icons cuestan ~550ms juntos. Defer via OnIdle ejecuta en
# background despues del primer prompt, terminal aparece al usuario sin esperar.
`$null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action {
    Import-Module posh-git -ErrorAction SilentlyContinue
    # Terminal-Icons reescribe sus XML (prefs/temas) en cada import: varias consolas
    # arrancando a la vez (m2/m3/m4) leen un fichero a medio escribir
    # ("Import-Clixml: Root element is missing"). Import serializado entre procesos.
    `$tiLock = New-Object System.Threading.Mutex(`$false, 'Local\Vorterm-TerminalIcons')
    try {
        try { [void]`$tiLock.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] {}
        Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    } finally {
        try { `$tiLock.ReleaseMutex() } catch {}
        `$tiLock.Dispose()
    }
}

# --- Aliases --------------------------------------------------
Set-Alias ll    Get-ChildItem
Set-Alias g     git
Set-Alias grep  Select-String
Set-Alias which Get-Command

function touch {
    param([Parameter(Mandatory)][string]`$Path)
    if (Test-Path `$Path) { (Get-Item `$Path).LastWriteTime = Get-Date }
    else { New-Item -ItemType File -Path `$Path | Out-Null }
}

# --- Convenience functions ------------------------------------
function Open-Profile { notepad `$PROFILE }
Set-Alias profile Open-Profile

function SysInfo {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber, OSArchitecture |
        Format-List
}

function Update-Modules {
    Get-InstalledModule | ForEach-Object { Update-Module `$_.Name -Force }
}

# --- HTML / web helpers ---------------------------------------
function open {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=`$true)] `$Rest)
    `$target = (`$Rest -join ' ').Trim()
    if (-not `$target) { `$target = '.' }
    Invoke-Item `$target
}

function html {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]`$Path)
    if (`$Path -match '^https?://') {
        Start-Process `$Path
    } elseif (Test-Path `$Path) {
        Start-Process (Resolve-Path `$Path).Path
    } else {
        Write-Error "Not a file or URL: `$Path"
    }
}

function serve {
    [CmdletBinding()]
    param([int]`$Port = 8000, [string]`$Path = '.')
    `$listener = [System.Net.HttpListener]::new()
    `$prefix = "http://localhost:`$Port/"
    `$listener.Prefixes.Add(`$prefix)
    `$root = (Resolve-Path `$Path).Path
    try {
        `$listener.Start()
        Write-Host "serving `$root at `$prefix  (Ctrl+C to stop)" -ForegroundColor Cyan
        while (`$listener.IsListening) {
            `$ctx = `$listener.GetContext()
            `$rel = [Uri]::UnescapeDataString(`$ctx.Request.Url.AbsolutePath.TrimStart('/'))
            if ([string]::IsNullOrWhiteSpace(`$rel)) { `$rel = 'index.html' }
            `$file = Join-Path `$root `$rel
            if (Test-Path `$file -PathType Leaf) {
                `$bytes = [System.IO.File]::ReadAllBytes(`$file)
                `$ext = [System.IO.Path]::GetExtension(`$file).ToLower()
                `$mime = switch (`$ext) {
                    '.html' {'text/html'}; '.htm' {'text/html'}
                    '.css'  {'text/css'};  '.js'  {'application/javascript'}
                    '.json' {'application/json'}
                    '.png'  {'image/png'}; '.jpg' {'image/jpeg'}; '.jpeg' {'image/jpeg'}
                    '.svg'  {'image/svg+xml'}; '.ico' {'image/x-icon'}
                    default {'application/octet-stream'}
                }
                `$ctx.Response.ContentType = `$mime
                `$ctx.Response.OutputStream.Write(`$bytes,0,`$bytes.Length)
            } else {
                `$ctx.Response.StatusCode = 404
                `$msg = [Text.Encoding]::UTF8.GetBytes("404 not found: `$rel")
                `$ctx.Response.OutputStream.Write(`$msg,0,`$msg.Length)
            }
            `$ctx.Response.OutputStream.Close()
        }
    } finally { `$listener.Stop(); `$listener.Close() }
}

# --- Elevation helper -----------------------------------------
function sudo {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments=`$true)] `$Rest)
    if (-not `$Rest -or `$Rest.Count -eq 0) {
        Start-Process pwsh -Verb RunAs
    } else {
        `$cmd = `$Rest -join ' '
        Start-Process pwsh -ArgumentList @('-NoExit','-Command',`$cmd) -Verb RunAs
    }
}

$multiPaneBlock

# --- Fallback prompt (only if oh-my-posh not active) ----------
if (-not `$script:_ompActive) {
    `$script:_hasGit = [bool](Get-Command git.exe -ErrorAction SilentlyContinue)
    function prompt {
        `$path = (Get-Location).Path
        `$branch = ''
        if (`$script:_hasGit) {
            `$b = git branch --show-current 2>`$null
            if (`$b) { `$branch = "  [`$b]" }
        }
        `$adminTag = ''
        if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            `$adminTag = ' (admin)'
        }
        Write-Host "[`$((Get-Date).ToString('HH:mm'))]`$adminTag `$path`$branch > " -ForegroundColor Cyan -NoNewline
        return ' '
    }
}

# --- Initial directory ----------------------------------------
if (-not `$global:__VortermStarted) {
    Set-Location '$escapedPath'
    `$global:__VortermStarted = `$true
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
}
"@

            # Validar sintaxis ANTES de escribir (nunca dejar un perfil roto)
            $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($profileContent, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                Write-Log "  [!!] perfil generado con errores de sintaxis, NO se escribe:"
                foreach ($pe in $parseErrors) { Write-Log "       $($pe.Message)" }
                $script:failures += 'profile-syntax'
            } elseif ($DRY) {
                Write-Log "  [DRY] sintaxis perfil OK. Escribiria:"
                Write-Log "  [DRY]   $ps7Path"
                Write-Log "  [DRY]   $ps5Path"
            } else {
                # Vorterm solo gestiona SU bloque entre marcadores. Lo que el usuario (u
                # otras herramientas, p.ej. el lanzador claude2 de Claude Code Setup Guide)
                # tenga fuera del bloque se conserva tal cual.
                #  - fichero con marcadores        -> se sustituye solo el bloque
                #  - perfil completo de 7.0 / 7.1  -> se migra a bloque (era 100% Vorterm)
                #  - perfil propio del usuario     -> bloque arriba + contenido del usuario debajo
                $begin = '# >>> vorterm >>>'
                $end   = '# <<< vorterm <<<'
                $block = "$begin (managed by Vorterm $($opts.Version); changes inside this block are replaced on the next install)`r`n" +
                         $profileContent.Trim() + "`r`n$end"
                foreach ($d in @($ps7Dir,$ps5Dir)) {
                    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
                }
                foreach ($t in @(@{P=$ps7Path;T='PS7'}, @{P=$ps5Path;T='PS5.1'})) {
                    try {
                        $old = $null
                        $new = $block + "`r`n"
                        if (Test-Path -LiteralPath $t.P) {
                            $old = [System.IO.File]::ReadAllText($t.P)
                            $bi = $old.IndexOf($begin)
                            $ei = $old.IndexOf($end)
                            if ($bi -ge 0 -and $ei -gt $bi) {
                                $new = $old.Substring(0, $bi) + $block + $old.Substring($ei + $end.Length)
                            } elseif ($old -match '^\s*# === Generated by Vorterm') {
                                Write-Log "  [..] $($t.T): perfil Vorterm antiguo, se migra a bloque gestionado"
                            } elseif ($old.Trim()) {
                                $new = $block + "`r`n`r`n" + $old
                                Write-Log "  [..] $($t.T): se conserva tu contenido debajo del bloque Vorterm"
                            }
                        }
                        if ($null -ne $old -and $old -ceq $new) {
                            Write-Log "  [OK] profile $($t.T) already up to date: $($t.P)"
                            continue
                        }
                        Backup-VortermFile $t.P
                        [System.IO.File]::WriteAllText($t.P, $new, (New-Object System.Text.UTF8Encoding $true))
                        Write-Log "  [OK] profile $($t.T): $($t.P)"
                    } catch {
                        Write-Log "  [!!] profile $($t.T): $($_.Exception.Message)"
                        $script:failures += "profile-$($t.T)"
                    }
                }
            }
        }

        # ---- Windows Terminal config ---------------------
        if ($opts.WTConfig) {
            Set-Status 'Windows Terminal config' 88

            # Fondo + icono del perfil: fondo de casquillos incluido en el repo
            # (assets\vorterm-bg.png; si falta, se descarga del repo) e icono moneda
            # BTC. Se copian a LOCALAPPDATA; el fondo se actualiza si el del repo cambia.
            $assetDir = Join-Path $env:LOCALAPPDATA 'Vorterm'
            $bgPath   = Join-Path $assetDir 'vorterm-bg.png'
            $icoPath  = Join-Path $assetDir 'vorterm-btc.png'
            $assets = @(
                @{ Path = $bgPath;  Src = $opts.BgSrc; Url = 'https://raw.githubusercontent.com/4leX-42/Vorterm/main/assets/vorterm-bg.png'; Tag = 'fondo' },
                @{ Path = $icoPath; Src = $null;       Url = 'https://cdn-icons-png.flaticon.com/512/5968/5968260.png';                         Tag = 'icono BTC' }
            )
            foreach ($a in $assets) {
                if ($DRY) { Write-Log "  [DRY] $($a.Tag) -> $($a.Path)"; continue }
                if ($a.Src -and (Test-Path -LiteralPath $a.Src)) {
                    try {
                        if (-not (Test-Path $assetDir)) { New-Item -ItemType Directory -Path $assetDir -Force | Out-Null }
                        if ((Test-Path -LiteralPath $a.Path) -and
                            (Get-FileHash -LiteralPath $a.Path).Hash -eq (Get-FileHash -LiteralPath $a.Src).Hash) {
                            Write-Log "  [OK] $($a.Tag) ya presente: $($a.Path)"
                        } else {
                            Copy-Item -LiteralPath $a.Src -Destination $a.Path -Force
                            Write-Log "  [OK] $($a.Tag): $($a.Path)"
                        }
                        continue
                    } catch {
                        Write-Log "  [..] $($a.Tag): copia local fallida ($($_.Exception.Message)), se descarga"
                    }
                }
                if (Test-Path $a.Path) { Write-Log "  [OK] $($a.Tag) ya presente: $($a.Path)"; continue }
                try {
                    if (-not (Test-Path $assetDir)) { New-Item -ItemType Directory -Path $assetDir -Force | Out-Null }
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $a.Url -OutFile $a.Path -UseBasicParsing -ErrorAction Stop
                    if ((Get-Item $a.Path).Length -lt 5kb) { throw 'descarga incompleta' }
                    Write-Log "  [OK] $($a.Tag) descargado: $($a.Path)"
                } catch {
                    Write-Log "  [!!] $($a.Tag): $($_.Exception.Message) (se sigue sin el)"
                    Remove-Item $a.Path -Force -ErrorAction SilentlyContinue
                    if ($a.Tag -eq 'fondo') { $bgPath = $null } else { $icoPath = $null }
                }
            }
            if ($DRY) { $bgPath = $null; $icoPath = $null }

            $wtCandidates = @(
                "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
                "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
                "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
            ) | Where-Object { Test-Path $_ }

            if (-not $wtCandidates) {
                Write-Log "  [!!] Windows Terminal settings.json not found (open WT once to generate it)"
            } else {
                $ps7Guid    = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
                $ps5Guid    = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
                $mosaicGuid = '{7628d9b6-6917-4040-b9a2-986f96f1361d}'
                # PowerShell portable (plan B) vive en el perfil del usuario: ruta completa
                # para no depender de que Windows Terminal ya vea el PATH de usuario nuevo.
                $pwshCmd = 'pwsh.exe -NoLogo -NoProfileLoadTime'
                if ($pwshExe -and $pwshExe -like "$env:LOCALAPPDATA\Microsoft\PowerShell\7\*") {
                    $pwshCmd = "`"$pwshExe`" -NoLogo -NoProfileLoadTime"
                }

                # WT settings.json es JSONC: comentarios // /* */ Y comas finales.
                # ConvertFrom-Json (PS5.1) revienta con ambos. Limpiar los dos
                # preservando strings.
                function Remove-JsonComments {
                    param([string]$Text)
                    $sb = [System.Text.StringBuilder]::new()
                    $inString = $false; $escape = $false
                    $i = 0; $len = $Text.Length
                    while ($i -lt $len) {
                        $c = $Text[$i]
                        if ($inString) {
                            [void]$sb.Append($c)
                            if ($escape)        { $escape = $false }
                            elseif ($c -eq '\') { $escape = $true }
                            elseif ($c -eq '"') { $inString = $false }
                            $i++
                        } else {
                            if ($c -eq '"') {
                                $inString = $true; [void]$sb.Append($c); $i++
                            } elseif ($c -eq '/' -and $i+1 -lt $len -and $Text[$i+1] -eq '/') {
                                while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                            } elseif ($c -eq '/' -and $i+1 -lt $len -and $Text[$i+1] -eq '*') {
                                $i += 2
                                while ($i+1 -lt $len -and -not ($Text[$i] -eq '*' -and $Text[$i+1] -eq '/')) { $i++ }
                                $i += 2
                            } elseif ($c -eq '}' -or $c -eq ']') {
                                # trailing comma: quitar la coma colgante previa
                                $j = $sb.Length - 1
                                while ($j -ge 0 -and [char]::IsWhiteSpace($sb[$j])) { $j-- }
                                if ($j -ge 0 -and $sb[$j] -eq ',') { [void]$sb.Remove($j, 1) }
                                [void]$sb.Append($c); $i++
                            } else {
                                [void]$sb.Append($c); $i++
                            }
                        }
                    }
                    $sb.ToString()
                }

                foreach ($wtJson in $wtCandidates) {
                    try {
                        $raw   = Get-Content $wtJson -Raw -Encoding UTF8
                        $clean = Remove-JsonComments $raw
                        $json  = $clean | ConvertFrom-Json

                        if ($DRY) {
                            Write-Log "  [DRY] parse OK: $wtJson"
                            Write-Log "  [DRY]   font -> '$nerdFontFace', defaultProfile -> PS7, startingDirectory -> $($opts.WorkDir)"
                            if ($opts.MultiPane) { Write-Log "  [DRY]   perfil oculto 'Vorterm Mosaic' + atajos Ctrl+Shift+3/B/Z (si estan libres)" }
                            if ($opts.Elevate) { Write-Log "  [DRY]   elevate -> true (UAC por pestana)" }
                            continue
                        }

                        # Serializacion de partida: solo se escribe (y se hace backup) si
                        # algo cambia de verdad. Segunda ejecucion = fichero intacto.
                        $before = $json | ConvertTo-Json -Depth 64

                        function Set-Prop {
                            param($obj, [string]$name, $value)
                            if ($obj.PSObject.Properties.Name -contains $name) {
                                $obj.$name = $value
                            } else {
                                $obj | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
                            }
                        }

                        # --- defaults.font + defaults.colorScheme -
                        if (-not $json.profiles) {
                            Set-Prop $json 'profiles' ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = @() })
                        }
                        if (-not $json.profiles.defaults) {
                            Set-Prop $json.profiles 'defaults' ([pscustomobject]@{})
                        }
                        if (-not $json.profiles.defaults.font) {
                            Set-Prop $json.profiles.defaults 'font' ([pscustomobject]@{ face = $nerdFontFace; size = 11 })
                        } else {
                            Set-Prop $json.profiles.defaults.font 'face' $nerdFontFace
                            if (-not ($json.profiles.defaults.font.PSObject.Properties.Name -contains 'size')) {
                                Set-Prop $json.profiles.defaults.font 'size' 11
                            }
                        }

                        # --- per-profile patch -----------------
                        $patched = $false
                        if ($json.profiles.list) {
                            foreach ($prof in $json.profiles.list) {
                                if ($prof.guid -eq $ps5Guid -or $prof.guid -eq $mosaicGuid) { continue }
                                # Solo el perfil PS7 de verdad: GUID/origen del perfil dinamico
                                # de WT, o un perfil llamado exactamente "PowerShell [7]" que
                                # lanza pwsh. NO cualquier perfil que mencione pwsh: perfiles
                                # propios del usuario (o el Mosaic) y "Developer PowerShell for
                                # VS" no se tocan.
                                $isPwsh = ($prof.guid -eq $ps7Guid) -or
                                          ($prof.source -eq 'Windows.Terminal.PowershellCore') -or
                                          (($prof.name -match '^(?i)PowerShell(\s*7(\.\d+)?)?$') -and
                                           ($prof.commandline -match '(?i)^\s*"?[^"]*pwsh(\.exe)?"?(\s|$)'))
                                if ($isPwsh) {
                                    Set-Prop $prof 'commandline' $pwshCmd
                                    Set-Prop $prof 'startingDirectory' $opts.WorkDir
                                    if ($opts.Elevate) {
                                        Set-Prop $prof 'elevate' $true
                                    }
                                    # Mismo bloque font que el equipo de referencia:
                                    # face + size 14 + weight normal + glyphs integrados a color
                                    if (-not $prof.font) {
                                        Set-Prop $prof 'font' ([pscustomobject]@{
                                            face = $nerdFontFace; size = 14; weight = 'normal'
                                            builtinGlyphs = $true; colorGlyphs = $true })
                                    } else {
                                        Set-Prop $prof.font 'face' $nerdFontFace
                                        Set-Prop $prof.font 'size' 14
                                        Set-Prop $prof.font 'weight' 'normal'
                                        Set-Prop $prof.font 'builtinGlyphs' $true
                                        Set-Prop $prof.font 'colorGlyphs' $true
                                        foreach ($k in 'cellHeight','cellWidth') {
                                            if ($prof.font.PSObject.Properties.Name -contains $k) {
                                                $prof.font.PSObject.Properties.Remove($k)
                                            }
                                        }
                                    }
                                    # Look del equipo de referencia: fondo, icono
                                    # BTC, cursor de barra, scrollbar visible. Fondo e
                                    # icono solo si el perfil no tiene ya uno propio.
                                    $vtDir = Join-Path $env:LOCALAPPDATA 'Vorterm'
                                    if ($bgPath -and (-not $prof.backgroundImage -or $prof.backgroundImage -like "$vtDir*")) {
                                        Set-Prop $prof 'backgroundImage' $bgPath
                                        Set-Prop $prof 'backgroundImageOpacity' 0.9
                                        Set-Prop $prof 'backgroundImageAlignment' 'bottomRight'
                                        Set-Prop $prof 'backgroundImageStretchMode' 'uniformToFill'
                                    }
                                    if ($icoPath -and (-not $prof.icon -or $prof.icon -like "$vtDir*" -or $prof.icon -like 'ms-appx*')) {
                                        Set-Prop $prof 'icon' $icoPath
                                    }
                                    Set-Prop $prof 'cursorShape' 'bar'
                                    Set-Prop $prof 'scrollbarState' 'visible'
                                    Set-Prop $prof 'adjustIndistinguishableColors' 'automatic'
                                    Write-Log "  [OK] WT profile patched: $($prof.name)"
                                    $patched = $true
                                }
                            }
                        }

                        if (-not $patched -and $pwshExe) {
                            # Add a PowerShell 7 entry if missing
                            $newProf = [pscustomobject]@{
                                guid              = $ps7Guid
                                name              = 'PowerShell'
                                commandline       = $pwshCmd
                                startingDirectory = $opts.WorkDir
                                hidden            = $false
                                cursorShape       = 'bar'
                                scrollbarState    = 'visible'
                                adjustIndistinguishableColors = 'automatic'
                                font              = [pscustomobject]@{
                                    face = $nerdFontFace; size = 14; weight = 'normal'
                                    builtinGlyphs = $true; colorGlyphs = $true }
                            }
                            if ($bgPath) {
                                Set-Prop $newProf 'backgroundImage' $bgPath
                                Set-Prop $newProf 'backgroundImageOpacity' 0.9
                                Set-Prop $newProf 'backgroundImageAlignment' 'bottomRight'
                                Set-Prop $newProf 'backgroundImageStretchMode' 'uniformToFill'
                            }
                            if ($icoPath) { Set-Prop $newProf 'icon' $icoPath }
                            if ($opts.Elevate) { Set-Prop $newProf 'elevate' $true }
                            if (-not $json.profiles.list) { Set-Prop $json.profiles 'list' @() }
                            $json.profiles.list = @($newProf) + @($json.profiles.list)
                            Write-Log "  [OK] WT profile added: PowerShell 7"
                        }

                        # --- defaultProfile -> PS7 -------------
                        if ($pwshExe) {
                            Set-Prop $json 'defaultProfile' $ps7Guid
                            Write-Log "  [OK] WT defaultProfile -> PowerShell 7"
                        }

                        # --- Multi-pane: perfil Mosaic + atajos ---
                        if ($opts.MultiPane) {
                            $mosaic = $null
                            foreach ($prof in @($json.profiles.list)) { if ($prof.guid -eq $mosaicGuid) { $mosaic = $prof } }
                            if (-not $mosaic) {
                                $mosaic = [pscustomobject]@{ guid = $mosaicGuid; name = 'Vorterm Mosaic' }
                                $json.profiles.list = @($json.profiles.list) + @($mosaic)
                                Write-Log "  [OK] WT profile added: Vorterm Mosaic (oculto, lo usan m2/m3/m4)"
                            }
                            $mpCmd = if ($pwshExe) { $pwshCmd } else { 'powershell.exe -NoLogo' }
                            Set-Prop $mosaic 'commandline' $mpCmd
                            Set-Prop $mosaic 'hidden' $true
                            Set-Prop $mosaic 'background' '#000000'
                            Set-Prop $mosaic 'opacity' 100
                            Set-Prop $mosaic 'useAcrylic' $false
                            Set-Prop $mosaic 'closeOnExit' 'always'
                            Set-Prop $mosaic 'cursorShape' 'bar'
                            Set-Prop $mosaic 'scrollbarState' 'visible'
                            Set-Prop $mosaic 'adjustIndistinguishableColors' 'automatic'
                            Set-Prop $mosaic 'intenseTextStyle' 'none'
                            if (-not $mosaic.font) {
                                Set-Prop $mosaic 'font' ([pscustomobject]@{
                                    face = $nerdFontFace; size = 14; weight = 'normal'
                                    builtinGlyphs = $true; colorGlyphs = $true })
                            } else {
                                Set-Prop $mosaic.font 'face' $nerdFontFace
                            }
                            foreach ($k in 'backgroundImage','backgroundImageOpacity') {
                                if ($mosaic.PSObject.Properties.Name -contains $k) { $mosaic.PSObject.Properties.Remove($k) }
                            }
                            if ($icoPath -and -not $mosaic.icon) { Set-Prop $mosaic 'icon' $icoPath }
                            if ($opts.Elevate) { Set-Prop $mosaic 'elevate' $true }

                            # Atajos: solo si la tecla esta libre. Nunca se pisa un atajo del usuario.
                            $split3 = [pscustomobject]@{
                                action  = 'multipleActions'
                                actions = @(
                                    [pscustomobject]@{ action = 'splitPane'; split = 'right'; size = 0.667; profile = $mosaicGuid },
                                    [pscustomobject]@{ action = 'splitPane'; split = 'right'; size = 0.5;   profile = $mosaicGuid })
                            }
                            $wanted = @(
                                @{ Id = 'User.VortermBroadcast'; Keys = 'ctrl+shift+b'; Command = 'toggleBroadcastInput'; Name = $null },
                                @{ Id = 'User.VortermZoom';      Keys = 'ctrl+shift+z'; Command = 'togglePaneZoom';       Name = $null },
                                @{ Id = 'User.VortermSplit3';    Keys = 'ctrl+shift+3'; Command = $split3;                Name = 'Vorterm: split tab in 3' }
                            )
                            if (-not ($json.PSObject.Properties.Name -contains 'actions'))     { Set-Prop $json 'actions' @() }
                            if (-not ($json.PSObject.Properties.Name -contains 'keybindings')) { Set-Prop $json 'keybindings' @() }
                            foreach ($w in $wanted) {
                                if (@($json.keybindings | Where-Object { $_.id -eq $w.Id }).Count -gt 0) { continue }
                                $bound = @(@($json.keybindings) + @($json.actions) | Where-Object { $_.keys } | ForEach-Object { $_.keys })
                                if ($bound -contains $w.Keys) {
                                    Write-Log "  [..] $($w.Keys) ya tiene un atajo propio, se respeta"
                                    continue
                                }
                                $act = [pscustomobject]@{ command = $w.Command; id = $w.Id }
                                if ($w.Name) { Set-Prop $act 'name' $w.Name }
                                if (@($json.actions | Where-Object { $_.id -eq $w.Id }).Count -eq 0) {
                                    $json.actions = @($json.actions) + @($act)
                                }
                                $json.keybindings = @($json.keybindings) + @([pscustomobject]@{ id = $w.Id; keys = $w.Keys })
                                Write-Log "  [OK] WT atajo $($w.Keys) -> $($w.Id)"
                            }
                        }

                        # --- write back (solo si hay cambios) -------
                        $out = $json | ConvertTo-Json -Depth 64
                        if ($out -ceq $before) {
                            Write-Log "  [OK] WT settings already up to date: $wtJson"
                        } else {
                            Backup-VortermFile $wtJson
                            [System.IO.File]::WriteAllText($wtJson, $out, (New-Object System.Text.UTF8Encoding $false))
                            Write-Log "  [OK] WT settings written: $wtJson"
                        }
                    } catch {
                        Write-Log "  [!!] WT cfg: $($_.Exception.Message)"
                        $script:failures += 'wt-config'
                    }
                }
            }
        }

        # ---- LAB (opcional, solo ficheros locales) ----
        # La logica vive en lab\New-VortermLab.ps1 (usable tambien por separado). Sin red,
        # sin inicio de sesion, sin admin y sin tocar Azure/M365: solo carpetas y plantillas.
        if ($opts.Lab) {
            Set-Status 'Lab' 91
            try {
                if (-not $opts.LabScript -or -not (Test-Path -LiteralPath $opts.LabScript)) {
                    throw "generador no encontrado: $($opts.LabScript) (falta la carpeta lab\ junto al instalador)"
                }
                $labRes = & $opts.LabScript -Root $opts.LabRoot -Adopt:([bool]$opts.LabAdopt) -DryRun:$DRY -PassThru
                $tag = if ($DRY) { 'DRY' } else { 'OK' }
                if ($labRes.ExitCode -eq 0) {
                    Write-Log ("  [{0}] LAB ({1}): {2}" -f $tag, $labRes.Mode, $labRes.LabPath)
                    Write-Log ("       creados {0} | actualizados {1} | sin cambios {2} | tuyos, no tocados {3} | carpetas {4}" -f `
                        $labRes.Created.Count, $labRes.Updated.Count, $labRes.Unchanged.Count, $labRes.Kept.Count, $labRes.Directories.Count)
                } else {
                    foreach ($e in $labRes.Errors) { Write-Log "  [!!] LAB: $e" }
                    $script:failures += 'lab'
                }
            } catch {
                Write-Log "  [!!] LAB: $($_.Exception.Message)"
                $script:failures += 'lab'
            }
        }

        # ---- Verify --------------------------------------
        if ($opts.Verify) {
            Set-Status 'Verify' 94

            # Smoke test: arrancar pwsh CON el perfil recien escrito y capturar
            # errores. Esto caza exactamente "abro la terminal y saltan errores".
            if ($pwshExe -and $opts.WriteProfile -and -not $DRY) {
                try {
                    Write-Log "  [..] smoke test: cargando perfil en pwsh..."
                    # Comillas simples: las dobles las quita el parser de argumentos de
                    # Windows y pwsh recibia __SMOKE_END__ como comando inexistente.
                    $smokeRaw = & $pwshExe -NoLogo -Command "'__SMOKE_END__'" 2>&1
                    $smokeErr = @($smokeRaw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                    if ($smokeErr.Count -gt 0) {
                        Write-Log "  [!!] el perfil emite errores al arrancar:"
                        foreach ($e in ($smokeErr | Select-Object -First 5)) { Write-Log "       $e" }
                        $script:failures += 'profile-smoke'
                    } else {
                        Write-Log "  [OK] perfil carga sin errores en PS7"
                    }
                } catch {
                    Write-Log "  [!!] smoke test: $($_.Exception.Message)"
                }
            } elseif ($DRY) {
                Write-Log "  [DRY] smoke test omitido (no se escribio perfil)"
            }

            if ($pwshExe -and $opts.Icons -and -not $DRY) {
                try {
                    # Sin comillas dobles dentro: PowerShell 5.1 las pierde al pasar a un exe
                    # un argumento con espacios ("OK" llegaba como OK -> comando inexistente).
                    $verifyCmd = "Import-Module Terminal-Icons -ErrorAction Stop; if (Get-Module Terminal-Icons) { 'OK' } else { 'MISSING' }"
                    $verifyOut = & $pwshExe -NoProfile -NoLogo -Command $verifyCmd 2>&1
                    if ($verifyOut -match 'OK') {
                        Write-Log "  [OK] Terminal-Icons loads cleanly in PS7"
                    } else {
                        Write-Log "  [!!] Terminal-Icons did not load: $verifyOut"
                        $script:failures += 'verify-Terminal-Icons'
                    }
                } catch {
                    Write-Log "  [!!] verify Terminal-Icons: $($_.Exception.Message)"
                }
            }

            if ($opts.OMP) {
                $ompExe = (Get-Command oh-my-posh -ErrorAction SilentlyContinue).Source
                if (-not $ompExe) {
                    $candidate = "$env:LOCALAPPDATA\Programs\oh-my-posh\bin\oh-my-posh.exe"
                    if (Test-Path $candidate) { $ompExe = $candidate }
                }
                if ($ompExe) {
                    Write-Log "  [OK] oh-my-posh: $ompExe"
                    if (Test-Path $userTheme) {
                        Write-Log "  [OK] theme present: $userTheme"
                    } elseif ($DRY) {
                        Write-Log "  [DRY] theme se escribiria en: $userTheme"
                    } else {
                        Write-Log "  [!!] theme missing: $userTheme"
                        $script:failures += 'omp-theme'
                    }
                } else {
                    Write-Log "  [!!] oh-my-posh.exe not found"
                    if (-not $DRY) { $script:failures += 'omp-bin' }
                }
            }

            # JetBrainsMono Nerd Font variants: "Nerd Font", "NF", "NFM", "NFP", "NL".
            # Solo "Nerd Font" full contiene literal "Nerd"; las demas siglas no.
            $nfRx = '(?i)(Nerd|\bN[FL][MP]?\b|JetBrainsMono\s*N[FL])'
            $hasFont = $false
            $detectedAs = ''
            foreach ($hive in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                              'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
                if (Test-Path $hive) {
                    $names = (Get-ItemProperty $hive).PSObject.Properties.Name |
                             Where-Object { $_ -notlike 'PS*' }
                    $hit = $names | Where-Object { $_ -match $nfRx } | Select-Object -First 1
                    if ($hit) { $hasFont = $true; $detectedAs = "registry: $hit"; break }
                }
            }
            if (-not $hasFont) {
                # Fallback: check Fonts folders directly (winget user install sometimes
                # drops files there before the registry refresh)
                $fontDirs = @("$env:WINDIR\Fonts",
                              (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'))
                foreach ($fd in $fontDirs) {
                    if (Test-Path $fd) {
                        $files = Get-ChildItem -Path (Join-Path $fd '*') -Include '*.ttf','*.otf' -File -ErrorAction SilentlyContinue |
                                 Select-Object -ExpandProperty Name
                        $hit = $files | Where-Object { $_ -match $nfRx } | Select-Object -First 1
                        if ($hit) { $hasFont = $true; $detectedAs = "file: $hit"; break }
                    }
                }
            }
            if ($hasFont) {
                Write-Log "  [OK] Nerd Font detected ($detectedAs)"
            } else {
                Write-Log "  [!!] No Nerd Font detected. ls icons will not render"
                if (-not $DRY) { $script:failures += 'nerd-font' }
            }

            if ($opts.MultiPane -and $opts.WriteProfile -and $pwshExe -and -not $DRY) {
                $mp = & $pwshExe -NoLogo -NonInteractive -Command "if ((Get-Command m3 -ErrorAction SilentlyContinue) -and (Get-Command close -ErrorAction SilentlyContinue)) { 'MP_OK' }" 2>$null
                if ($mp -match 'MP_OK') {
                    Write-Log "  [OK] multi-pane: m2 / m3 / m4, close N, /commands"
                } else {
                    Write-Log "  [!!] multi-pane functions not loaded by the profile"
                    $script:failures += 'multipane'
                }
            }

            if ($opts.Lab -and -not $DRY) {
                $labMarker = Join-Path (Join-Path $opts.LabRoot 'LAB') '.vorterm-lab.json'
                if (Test-Path -LiteralPath $labMarker) {
                    Write-Log "  [OK] LAB ready: $(Split-Path $labMarker -Parent)"
                } else {
                    Write-Log "  [!!] LAB marker missing: $labMarker"
                    $script:failures += 'lab-verify'
                }
            }
        }

        # ---- Done ----------------------------------------
        Set-Status $(if ($DRY) { 'Dry run done' } else { 'Done' }) 100
        $elapsed = (Get-Date) - $started
        Write-Log ""
        Write-Log "============================================================"
        if ($DRY) {
            Write-Log "  DRY RUN completado. Nada se ha modificado."
            if ($script:failures.Count -gt 0) {
                Write-Log "  Avisos: $($script:failures -join ', ')"
            }
        } elseif ($script:failures.Count -gt 0) {
            Write-Log "  Finished with warnings: $($script:failures -join ', ')"
        } else {
            Write-Log "  All green. System ready."
        }
        Write-Log ("  Elapsed: {0:N1}s" -f $elapsed.TotalSeconds)
        Write-Log "============================================================"
        Write-Log ""
        Write-Log "Reinicia Windows Terminal para cargar fuente + tema."
        if ($opts.Elevate) { Write-Log "Aviso: pestanas PS7 elevadas -> UAC por pestana." }
        Write-Log "Glifos como cajas? WT Settings -> PowerShell -> Appearance -> Font -> Nerd Font."
        Write-Log "Helpers: html, open, serve, sudo, touch, profile, SysInfo, Update-Modules."
        if ($opts.MultiPane) { Write-Log "Multi-pane: m2 / m3 / m4 [-Rows] [-Claude], close N, /commands." }
        if ($opts.Lab) { Write-Log "LAB: abre $(Join-Path $opts.LabRoot 'LAB')\README.md para empezar." }
        if ($opts.LogFile) { Write-Log "Log completo: $($opts.LogFile)" }

    } catch {
        # Excepcion no controlada: registrar SIEMPRE, no dejar la GUI colgada.
        Write-Log ""
        Write-Log "  [!!] ERROR FATAL: $($_.Exception.Message)"
        Write-Log "       $($_.ScriptStackTrace)"
        $script:failures += 'fatal'
        Set-Status 'Error' 100
    } finally {
        if (-not $sync.NoGui) {
            $sync.Window.Dispatcher.Invoke([action]{
                $sync.InstallBtn.IsEnabled = $true
                $sync.ResetBtn.IsEnabled   = $true
                $sync.PauseBtn.Visibility  = [System.Windows.Visibility]::Collapsed
                # Final: barra al 100 % en verde neon (ok), ambar (avisos) o rojo (error) + aviso.
                if ($script:failures -contains 'fatal') {
                    $sync.StatusText.Text = 'Error'; $hex = '#ff1a1a'
                    $title = 'OPERATION FAILED'
                    $body  = "Stopped by an error.`nLog: $($opts.LogFile)"
                } elseif ($script:failures.Count) {
                    $sync.StatusText.Text = 'Finished with warnings'; $hex = '#ff9f1a'
                    $title = 'COMPLETE // WARNINGS'
                    $body  = "Warnings: $($script:failures -join ', ')`nLog: $($opts.LogFile)"
                } else {
                    $sync.StatusText.Text = $(if ($opts.DryRun) { 'Dry run OK' } else { 'Finished' }); $hex = '#39ff14'
                    $title = $(if ($opts.DryRun) { 'DRY RUN COMPLETE' } else { 'OPERATION COMPLETE' })
                    $body  = $(if ($opts.DryRun) { 'Nothing was changed.' } else { 'All systems online. Restart Windows Terminal to load the font and theme.' })
                    if ($opts.Lab -and -not $opts.DryRun) { $body += "`nLab: $(Join-Path $opts.LabRoot 'LAB')" }
                }
                $brush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($hex)
                $sync.Progress.Value = 100
                $sync.Progress.Foreground = $brush
                try { $sync.Progress.Effect.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex) } catch {}
                $sync.StatusText.Foreground = $brush
                # Ventana propia (XAML en $sync.FinishXaml). Sin handlers de PowerShell: el
                # boton cierra con IsCancel, asi no hay bloqueo entre este hilo y el de la GUI.
                try {
                    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$sync.FinishXaml)))
                    $dlg.Owner = $sync.Window
                    $dlg.FindName('FinTitle').Text = $title
                    $dlg.FindName('FinBody').Text  = $body
                    # Acento segun resultado: verde (ok), naranja (avisos), rojo (error)
                    $accC = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
                    $accB = New-Object System.Windows.Media.SolidColorBrush $accC
                    $dlg.FindName('FinTitle').Foreground = $accB
                    try { $dlg.FindName('FinTitle').Effect.Color = $accC } catch {}
                    $dlg.FindName('FinBorder').BorderBrush = $accB
                    $dlg.FindName('FinOk').Foreground  = $accB
                    $dlg.FindName('FinOk').BorderBrush = $accB
                    [void]$dlg.ShowDialog()
                } catch {}
            })
        }
    }
}

# =============================================================
#  RESET LOGIC (compartida)
# =============================================================
$ResetLogic = {

    function Write-Log {
        param([string]$Msg)
        if ($sync.NoGui) { Write-Host $Msg; return }
        $sync.Window.Dispatcher.Invoke([action]{
            $color = '#d9d9d9'
            if     ($Msg -match '\[OK\]')  { $color = '#fcee0a' }
            elseif ($Msg -match '\[!!\]')  { $color = '#ff2b4a' }
            elseif ($Msg -match '\[DRY\]') { $color = '#66d9ff' }
            elseif ($Msg -match '\[\.\.\]'){ $color = '#6a6c70' }
            elseif ($Msg -match '^\s*=+')  { $color = '#8a8104' }
            $run = New-Object System.Windows.Documents.Run($Msg)
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($color)
            [void]$sync.LogPara.Inlines.Add($run)
            [void]$sync.LogPara.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
            $sync.LogBox.ScrollToEnd()
        })
    }
    function Set-Status {
        param([string]$Text, [int]$Pct = -1)
        if ($sync.NoGui) { Write-Host ">> $Text" -ForegroundColor DarkYellow; return }
        $sync.Window.Dispatcher.Invoke([action]{
            $sync.StatusText.Text = $Text
            if ($Pct -ge 0) { $sync.Progress.Value = $Pct }
        })
    }

    function Remove-JsonComments {
        param([string]$Text)
        $sb = [System.Text.StringBuilder]::new()
        $inString = $false; $escape = $false
        $i = 0; $len = $Text.Length
        while ($i -lt $len) {
            $c = $Text[$i]
            if ($inString) {
                [void]$sb.Append($c)
                if ($escape)        { $escape = $false }
                elseif ($c -eq '\') { $escape = $true }
                elseif ($c -eq '"') { $inString = $false }
                $i++
            } else {
                if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++ }
                elseif ($c -eq '/' -and $i+1 -lt $len -and $Text[$i+1] -eq '/') {
                    while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
                } elseif ($c -eq '/' -and $i+1 -lt $len -and $Text[$i+1] -eq '*') {
                    $i += 2
                    while ($i+1 -lt $len -and -not ($Text[$i] -eq '*' -and $Text[$i+1] -eq '/')) { $i++ }
                    $i += 2
                } elseif ($c -eq '}' -or $c -eq ']') {
                    $j = $sb.Length - 1
                    while ($j -ge 0 -and [char]::IsWhiteSpace($sb[$j])) { $j-- }
                    if ($j -ge 0 -and $sb[$j] -eq ',') { [void]$sb.Remove($j, 1) }
                    [void]$sb.Append($c); $i++
                } else {
                    [void]$sb.Append($c); $i++
                }
            }
        }
        $sb.ToString()
    }

    $ErrorActionPreference = 'Continue'
    $started   = Get-Date
    $failures  = @()
    $stamp     = Get-Date -Format yyyyMMddHHmmss
    $DRY       = [bool]$opts.DryRun

    try {

        Write-Log "============================================================"
        Write-Log "  Vorterm deep reset  $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
        if ($DRY) {
        Write-Log "  MODO DRY RUN - simulacion, no se modifica NADA"
        }
        Write-Log "============================================================"
        Write-Log ""

        # ---- 1. Profiles --------------------------------
        if ($opts.CleanProfile) {
            Set-Status 'Profiles' 8
            # Cubrir Documents local Y redirigido (OneDrive Known Folder Move):
            # pwsh carga $PROFILE de la carpeta real; limpiar solo una deja
            # perfiles viejos activos que pisan el tema en la proxima instalacion.
            $docsCandidates = @((Join-Path $env:USERPROFILE 'Documents'))
            try {
                $realDocs = [Environment]::GetFolderPath('MyDocuments')
                if ($realDocs) { $docsCandidates += $realDocs }
            } catch {}
            if ($env:OneDrive) {
                $docsCandidates += (Join-Path $env:OneDrive 'Documents')
                $docsCandidates += (Join-Path $env:OneDrive 'Documentos')
            }
            $profileDirs = @()
            foreach ($docs in ($docsCandidates | Sort-Object -Unique)) {
                $profileDirs += (Join-Path $docs 'PowerShell')
                $profileDirs += (Join-Path $docs 'WindowsPowerShell')
            }
            $profileNames = @(
                'profile.ps1',
                'Microsoft.PowerShell_profile.ps1',
                'Microsoft.PowerShellISE_profile.ps1',
                'Microsoft.VSCode_profile.ps1'
            )
            # Solo se toca lo que es de Vorterm, y siempre con copia .before-reset-* antes:
            #  - bloque entre marcadores (7.2+) -> se quita el bloque, el resto se conserva
            #  - perfil completo antiguo (7.0/7.1) -> se restaura el ultimo backup que NO
            #    sea de Vorterm (= el perfil que habia antes); sin el, se aparta y se borra
            #  - cualquier otro perfil -> no se toca
            $begin = '# >>> vorterm >>>'
            $end   = '# <<< vorterm <<<'
            foreach ($d in $profileDirs) {
                if (-not (Test-Path $d)) { continue }
                foreach ($n in $profileNames) {
                    $p = Join-Path $d $n
                    if (-not (Test-Path -LiteralPath $p)) { continue }
                    try {
                        $txt = [IO.File]::ReadAllText($p)
                        $bi = $txt.IndexOf($begin)
                        $ei = $txt.IndexOf($end)
                        $safety = "$p.before-reset-$stamp"
                        if ($bi -ge 0 -and $ei -gt $bi) {
                            $rest = ($txt.Substring(0, $bi) + $txt.Substring($ei + $end.Length)).Trim()
                            if ($DRY) { Write-Log "  [DRY] quitaria el bloque Vorterm de $p (se conserva el resto)"; continue }
                            Copy-Item -LiteralPath $p -Destination $safety -Force
                            if ($rest) {
                                [IO.File]::WriteAllText($p, $rest + "`r`n", (New-Object Text.UTF8Encoding $true))
                                Write-Log "  [OK] Vorterm block removed, your content kept: $p"
                            } else {
                                Remove-Item -LiteralPath $p -Force
                                Write-Log "  [OK] removed $p (only had the Vorterm block)"
                            }
                            Write-Log "       safety copy: $safety"
                        } elseif ($txt -match '^\s*# === Generated by Vorterm') {
                            $orig = Get-ChildItem -Path "$p.bak-*" -File -ErrorAction SilentlyContinue |
                                    Sort-Object LastWriteTime -Descending |
                                    Where-Object { -not ([IO.File]::ReadAllText($_.FullName) -match '^\s*# === Generated by Vorterm') } |
                                    Select-Object -First 1
                            if ($DRY) {
                                if ($orig) { Write-Log "  [DRY] restauraria $p desde $($orig.Name)" }
                                else       { Write-Log "  [DRY] apartaria $p (perfil Vorterm antiguo sin backup previo)" }
                                continue
                            }
                            Copy-Item -LiteralPath $p -Destination $safety -Force
                            if ($orig) {
                                Copy-Item -LiteralPath $orig.FullName -Destination $p -Force
                                Write-Log "  [OK] restored $p from $($orig.Name)"
                            } else {
                                Remove-Item -LiteralPath $p -Force
                                Write-Log "  [OK] removed old Vorterm profile $p"
                            }
                            Write-Log "       safety copy: $safety"
                        } else {
                            Write-Log "  [..] not a Vorterm profile, left untouched: $p"
                        }
                    } catch {
                        Write-Log "  [!!] $p : $($_.Exception.Message)"
                        $failures += "profile-$n"
                    }
                }
            }

            # Cache de init de oh-my-posh del perfil Vorterm (solo esos ficheros; los
            # assets de Windows Terminal y los logs se quedan)
            $ompCacheDir = Join-Path $env:LOCALAPPDATA 'Vorterm'
            $ompCaches = @(Get-ChildItem -Path (Join-Path $ompCacheDir 'omp-init*.ps1') -File -ErrorAction SilentlyContinue)
            foreach ($c in $ompCaches) {
                if ($DRY) { Write-Log "  [DRY] borraria cache OMP: $($c.FullName)"; continue }
                try {
                    Remove-Item -LiteralPath $c.FullName -Force -ErrorAction Stop
                    Write-Log "  [OK] removed OMP init cache: $($c.Name)"
                } catch {
                    Write-Log "  [!!] cache: $($_.Exception.Message)"
                }
            }
        }

        # ---- 2. PSReadLine history ----------------------
        if ($opts.CleanHistory) {
            Set-Status 'History' 25
            $hDir = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine'
            if (Test-Path $hDir) {
                $hFiles = Get-ChildItem -Path $hDir -Filter '*_history.txt' -File -ErrorAction SilentlyContinue
                if (-not $hFiles) {
                    Write-Log "  [..] no history files in $hDir"
                } else {
                    foreach ($hf in $hFiles) {
                        try {
                            if ($DRY) { Write-Log "  [DRY] borraria $($hf.Name)"; continue }
                            Remove-Item $hf.FullName -Force
                            Write-Log "  [OK] cleared $($hf.Name)"
                        } catch {
                            Write-Log "  [!!] $($hf.Name) : $($_.Exception.Message)"
                            $failures += "history-$($hf.Name)"
                        }
                    }
                }
            } else {
                Write-Log "  [..] $hDir not present"
            }
            if (-not $DRY) {
                try {
                    Clear-History -ErrorAction SilentlyContinue
                    Write-Log "  [OK] in-session history cleared"
                } catch {}
            }
        }

        # ---- 3. Terminal/prompt modules -----------------
        if ($opts.CleanModules) {
            Set-Status 'Modules' 45

            # Solo los modulos que instala Vorterm, y solo las copias de USUARIO que
            # Save-Module dejo en la carpeta de modulos de PowerShell 7 (local u OneDrive).
            # La PSReadLine que trae Windows / PowerShell 7 y cualquier otro modulo
            # (Az, Graph, EXO, z, PSFzf...) no se tocan.
            $docsList = @((Join-Path $env:USERPROFILE 'Documents'))
            try { $rd = [Environment]::GetFolderPath('MyDocuments'); if ($rd) { $docsList += $rd } } catch {}
            $modRoots = $docsList | Sort-Object -Unique | ForEach-Object { Join-Path $_ 'PowerShell\Modules' } |
                        Where-Object { Test-Path -LiteralPath $_ }
            foreach ($name in 'Terminal-Icons', 'posh-git', 'PSReadLine') {
                foreach ($mr in $modRoots) {
                    $modDir = Join-Path $mr $name
                    if (-not (Test-Path -LiteralPath $modDir)) { continue }
                    if ($DRY) { Write-Log "  [DRY] borraria modulo de usuario: $modDir"; continue }
                    try {
                        Remove-Item -LiteralPath $modDir -Recurse -Force -ErrorAction Stop
                        Write-Log "  [OK] removed $name ($modDir)"
                    } catch {
                        Write-Log "  [!!] $name at $modDir : $($_.Exception.Message) (cierra las consolas pwsh abiertas)"
                        $failures += "module-$name"
                    }
                }
            }

            # oh-my-posh winget package
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                try {
                    $omp = winget list --id JanDeDobbeleer.OhMyPosh -e --accept-source-agreements 2>$null | Out-String
                    if ($omp -match 'JanDeDobbeleer\.OhMyPosh') {
                        if ($DRY) {
                            Write-Log "  [DRY] desinstalaria oh-my-posh (winget)"
                        } else {
                            Write-Log "  [..] uninstalling oh-my-posh (winget package)..."
                            winget uninstall --id JanDeDobbeleer.OhMyPosh -e --silent --disable-interactivity 2>&1 | Out-Null
                            Write-Log "  [OK] oh-my-posh winget package removed"
                        }
                    }
                } catch { Write-Log "  [..] winget oh-my-posh check skipped" }
            }
        }

        # ---- 4. Windows Terminal ------------------------
        if ($opts.CleanWT) {
            Set-Status 'Windows Terminal' 80
            $wtCandidates = @(
                "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
                "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
                "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
            ) | Where-Object { Test-Path $_ }

            if (-not $wtCandidates) {
                Write-Log "  [..] no Windows Terminal settings.json found"
            } else {
                $signature = 'pwsh.exe -NoLogo -NoProfileLoadTime'
                $ps7Guid   = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

                $mosaicGuid = '{7628d9b6-6917-4040-b9a2-986f96f1361d}'
                $vtDir      = Join-Path $env:LOCALAPPDATA 'Vorterm'
                foreach ($wt in $wtCandidates) {
                    try {
                        # 7.2+: copia tomada la primera vez que Vorterm toco el fichero.
                        # Se guarda el estado actual antes de restaurar.
                        $orig = "$wt.vorterm-original"
                        if (Test-Path -LiteralPath $orig) {
                            if ($DRY) { Write-Log "  [DRY] restauraria $wt desde $(Split-Path $orig -Leaf)"; continue }
                            Copy-Item -LiteralPath $wt -Destination "$wt.before-reset-$stamp" -Force
                            Copy-Item -LiteralPath $orig -Destination $wt -Force
                            Remove-Item -LiteralPath $orig -Force
                            Write-Log "  [OK] restored $wt (state before Vorterm)"
                            Write-Log "       safety copy: $wt.before-reset-$stamp"
                            continue
                        }

                        # No backup: strip Vorterm markers in-place
                        if ($DRY) { Write-Log "  [DRY] limpiaria claves Vorterm en $wt"; continue }
                        Write-Log "  [..] no backup for $wt, stripping Vorterm keys..."
                        $bk = "$wt.before-reset-$stamp"
                        Copy-Item $wt $bk -Force

                        $raw   = Get-Content $wt -Raw -Encoding UTF8
                        $clean = Remove-JsonComments $raw
                        $json  = $clean | ConvertFrom-Json

                        $changed = $false

                        if ($json.profiles -and $json.profiles.list) {
                            foreach ($prof in $json.profiles.list) {
                                $isPwsh = ($prof.guid -eq $ps7Guid) -or
                                          ($prof.commandline -eq $signature) -or
                                          ($prof.commandline -match 'NoProfileLoadTime')
                                if (-not $isPwsh) { continue }

                                foreach ($k in 'commandline','font','elevate','startingDirectory') {
                                    if ($prof.PSObject.Properties.Name -contains $k) {
                                        $prof.PSObject.Properties.Remove($k)
                                        $changed = $true
                                    }
                                }
                                foreach ($k in 'backgroundImage','icon') {
                                    if ($prof.$k -and $prof.$k -like "$vtDir*") {
                                        $prof.PSObject.Properties.Remove($k)
                                        if ($k -eq 'backgroundImage') { $prof.PSObject.Properties.Remove('backgroundImageOpacity') }
                                        $changed = $true
                                    }
                                }
                                Write-Log "  [OK] stripped keys from profile: $($prof.name)"
                            }
                            $kept = @($json.profiles.list | Where-Object { $_.guid -ne $mosaicGuid })
                            if ($kept.Count -ne @($json.profiles.list).Count) {
                                $json.profiles.list = $kept
                                $changed = $true
                                Write-Log "  [OK] removed hidden profile Vorterm Mosaic"
                            }
                        }

                        foreach ($arr in 'actions','keybindings') {
                            if ($json.PSObject.Properties.Name -contains $arr) {
                                $keep = @($json.$arr | Where-Object { -not ($_.id -like 'User.Vorterm*') })
                                if ($keep.Count -ne @($json.$arr).Count) {
                                    $json.$arr = $keep
                                    $changed = $true
                                    Write-Log "  [OK] removed Vorterm $arr"
                                }
                            }
                        }

                        if ($json.profiles -and
                            $json.profiles.defaults -and
                            $json.profiles.defaults.font -and
                            $json.profiles.defaults.font.face -match '(?i)Nerd') {
                            $json.profiles.defaults.PSObject.Properties.Remove('font')
                            $changed = $true
                            Write-Log "  [OK] removed defaults.font (Nerd font marker)"
                        }

                        if ($changed) {
                            $out = $json | ConvertTo-Json -Depth 64
                            [System.IO.File]::WriteAllText($wt, $out, (New-Object System.Text.UTF8Encoding $false))
                            Write-Log "  [OK] saved cleaned $wt"
                            Write-Log "       safety copy: $bk"
                        } else {
                            Remove-Item $bk -Force
                            Write-Log "  [..] no Vorterm markers found, file unchanged"
                        }
                    } catch {
                        Write-Log "  [!!] $wt : $($_.Exception.Message)"
                        $failures += 'wt'
                    }
                }
            }
        }

        Set-Status $(if ($DRY) { 'Dry run done' } else { 'Done' }) 100
        $elapsed = (Get-Date) - $started
        Write-Log ""
        Write-Log "============================================================"
        if ($DRY) {
            Write-Log "  DRY RUN de reset completado. Nada se ha modificado."
        } elseif ($failures.Count) {
            Write-Log "  Reset finished with warnings: $($failures -join ', ')"
        } else {
            Write-Log "  Deep reset complete. Terminal back to clean state."
        }
        Write-Log ("  Elapsed: {0:N1}s" -f $elapsed.TotalSeconds)
        Write-Log "============================================================"
        Write-Log ""
        Write-Log "Untouched: PowerShell 7, Git, Windows Terminal, Nerd Font, Az/Graph/EXO modules, ~\.poshthemes."
        Write-Log "Open a new terminal window to see the clean state (current session keeps loaded modules in memory)."

    } catch {
        Write-Log ""
        Write-Log "  [!!] ERROR FATAL: $($_.Exception.Message)"
        Write-Log "       $($_.ScriptStackTrace)"
        $failures += 'fatal'
        Set-Status 'Error' 100
    } finally {
        $script:resetFailures = $failures
        if (-not $sync.NoGui) {
            $sync.Window.Dispatcher.Invoke([action]{
                $sync.InstallBtn.IsEnabled = $true
                $sync.ResetBtn.IsEnabled   = $true
                if ($failures -contains 'fatal') {
                    $sync.StatusText.Text = 'Error'; $hex = '#ff1a1a'
                    $title = 'RESET FAILED'; $body = 'Stopped by an error. Check the console.'
                } elseif ($failures.Count) {
                    $sync.StatusText.Text = 'Reset with warnings'; $hex = '#ff9f1a'
                    $title = 'RESET // WARNINGS'; $body = "Warnings: $($failures -join ', ')"
                } else {
                    $sync.StatusText.Text = $(if ($opts.DryRun) { 'Dry run OK' } else { 'Reset done' }); $hex = '#39ff14'
                    $title = 'RESET COMPLETE'; $body = 'Open a new terminal to see the clean state.'
                }
                $brush = [System.Windows.Media.BrushConverter]::new().ConvertFrom($hex)
                $sync.Progress.Value = 100
                $sync.Progress.Foreground = $brush
                try { $sync.Progress.Effect.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex) } catch {}
                $sync.StatusText.Foreground = $brush
                try {
                    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$sync.FinishXaml)))
                    $dlg.Owner = $sync.Window
                    $dlg.FindName('FinTitle').Text = $title
                    $dlg.FindName('FinBody').Text  = $body
                    # Acento segun resultado: verde (ok), naranja (avisos), rojo (error)
                    $accC = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
                    $accB = New-Object System.Windows.Media.SolidColorBrush $accC
                    $dlg.FindName('FinTitle').Foreground = $accB
                    try { $dlg.FindName('FinTitle').Effect.Color = $accC } catch {}
                    $dlg.FindName('FinBorder').BorderBrush = $accB
                    $dlg.FindName('FinOk').Foreground  = $accB
                    $dlg.FindName('FinOk').BorderBrush = $accB
                    [void]$dlg.ShowDialog()
                } catch {}
            })
        }
    }
}

# =============================================================
#  CONSOLE MODE (-NoGui): para pruebas y automatizacion
# =============================================================
function Get-DefaultDocs {
    $d = try { [Environment]::GetFolderPath('MyDocuments') } catch { $null }
    if (-not $d) { $d = Join-Path $env:USERPROFILE 'Documents' }
    return $d
}

function New-VortermLogFile {
    param([string]$Kind)
    $dir = Join-Path $env:LOCALAPPDATA 'Vorterm\logs'
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        return (Join-Path $dir ("{0}-{1}.log" -f $Kind, (Get-Date -Format yyyyMMdd-HHmmss)))
    } catch { return $null }
}

$script:LabScriptPath = $null
$script:BgSrc = $null
if ($PSScriptRoot) { $script:BgSrc = Join-Path $PSScriptRoot 'assets\vorterm-bg.png' }
if ($PSScriptRoot) { $script:LabScriptPath = Join-Path $PSScriptRoot 'lab\New-VortermLab.ps1' }

if ($NoGui) {
    $sync = @{
        NoGui       = $true
        ActiveProcs = [System.Collections.ArrayList]::new()
        Paused      = $false
    }
    if ($Reset) {
        $opts = @{
            CleanProfile = $true
            CleanHistory = $false
            CleanModules = $true
            CleanWT      = $true
            DryRun       = [bool]$DryRun
        }
        & $ResetLogic
        if ($script:resetFailures -and @($script:resetFailures).Count -gt 0) { exit 1 }
        exit 0
    }
    $opts = @{
        Version      = $script:VortermVersion
        WorkDir      = $(if ($WorkDir) { $WorkDir } else { Get-DefaultDocs })
        Pwsh         = $true
        Git          = $true
        WT           = $true
        Font         = $true
        OMP          = $true
        PSRL         = $true
        Icons        = $true
        PoshGit      = $true
        WriteProfile = $true
        WTConfig     = $true
        MultiPane    = -not $NoMultiPane
        Elevate      = $false
        VSCode       = [bool]$VSCode
        Neovim       = $false
        SevenZip     = $false
        GitHubDesktop = $false
        WSL          = $false
        ClaudeCode   = [bool]$ClaudeCode
        Codex        = $false
        Antigravity  = $false
        Node         = [bool]$Node
        Lab          = [bool]$LabRoot
        LabRoot      = $LabRoot
        LabAdopt     = [bool]$LabAdopt
        LabScript    = $script:LabScriptPath
        BgSrc        = $script:BgSrc
        Policy       = $true
        Verify       = $true
        DryRun       = [bool]$DryRun
        LogFile      = $(if ($DryRun) { $null } else { New-VortermLogFile 'install' })
        ThemeFile    = $script:ThemeFileName
        ThemeSrc     = $script:ThemeSrc
        ThemeJson    = $script:ThemeJson
    }
    & $InstallLogic
    if ($script:failures.Count -gt 0) { exit 1 }
    exit 0
}

# =============================================================
#  GUI MODE
# =============================================================

# ------ XAML ------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vorterm 7.2"
        Height="940" Width="1700"
        MinHeight="560" MinWidth="980"
        WindowStartupLocation="CenterScreen"
        Background="#050506"
        FontFamily="Inter, Segoe UI"
        FontSize="16"
        Foreground="#e8e8e8"
        ResizeMode="CanResize">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"          Color="#050506"/>
    <SolidColorBrush x:Key="Surface"     Color="#0c0d0f"/>
    <SolidColorBrush x:Key="Surface2"    Color="#121316"/>
    <SolidColorBrush x:Key="Border1"     Color="#1f2024"/>
    <SolidColorBrush x:Key="BorderStrong" Color="#3a3b40"/>
    <SolidColorBrush x:Key="Text"        Color="#e8e8e8"/>
    <SolidColorBrush x:Key="Muted"       Color="#6a6c70"/>
    <SolidColorBrush x:Key="Dim"         Color="#2a2b2f"/>
    <SolidColorBrush x:Key="Gold"        Color="#fcee0a"/>
    <SolidColorBrush x:Key="GoldHi"      Color="#fff86b"/>
    <SolidColorBrush x:Key="GoldDim"     Color="#8a8104"/>
    <SolidColorBrush x:Key="GoldFaint"   Color="#3a3601"/>
    <SolidColorBrush x:Key="Danger"      Color="#e10024"/>
    <SolidColorBrush x:Key="Cyan"        Color="#66d9ff"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#e8e8e8"/>
      <Setter Property="FontSize" Value="16"/>
    </Style>

    <Style x:Key="GroupLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource GoldDim}"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,10,0,2"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#e8e8e8"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="0,5,12,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FontFamily" Value="Bahnschrift Light, Bahnschrift, Segoe UI Light"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#121316"/>
      <Setter Property="Foreground" Value="#e8e8e8"/>
      <Setter Property="BorderBrush" Value="#3a3b40"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#e8e8e8"/>
      <Setter Property="CaretBrush" Value="{StaticResource Gold}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderStrong}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="2,9"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="16"/>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="BorderBrush" Value="{StaticResource GoldFaint}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="26,11"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource Gold}"/>
                <Setter TargetName="bd" Property="Background" Value="#0c0d02"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1a1802"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WarningButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Foreground" Value="{StaticResource Danger}"/>
      <Setter Property="BorderBrush" Value="#7a0015"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource GhostButton}">
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="42,11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd"
                    Background="Transparent"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}">
              <Border.Effect>
                <DropShadowEffect x:Name="glow" Color="#fcee0a" BlurRadius="14" ShadowDepth="0" Opacity="0.7"/>
              </Border.Effect>
              <ContentPresenter HorizontalAlignment="Center"
                                VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{StaticResource GoldHi}"/>
                <Setter TargetName="bd" Property="Background" Value="#0c0d02"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1a1802"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Background" Value="{StaticResource Dim}"/>
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style x:Key="RomanLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,0"/>
    </Style>

    <Style x:Key="SectionRule" TargetType="Border">
      <Setter Property="Height" Value="1"/>
      <Setter Property="Background" Value="{StaticResource GoldFaint}"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="Margin" Value="0,8,0,14"/>
    </Style>

    <Style x:Key="PathLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Gold}"/>
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,8,0,2"/>
    </Style>

    <Style x:Key="PathValue" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,0"/>
    </Style>

    <!-- Tron-style corner brackets (4 small L-shapes around content) -->
    <Style x:Key="CornerTL" TargetType="Border">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
      <Setter Property="BorderThickness" Value="1,1,0,0"/>
    </Style>
    <Style x:Key="CornerTR" TargetType="Border">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
      <Setter Property="BorderThickness" Value="0,1,1,0"/>
    </Style>
    <Style x:Key="CornerBL" TargetType="Border">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
      <Setter Property="BorderThickness" Value="1,0,0,1"/>
    </Style>
    <Style x:Key="CornerBR" TargetType="Border">
      <Setter Property="Width" Value="12"/>
      <Setter Property="Height" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
      <Setter Property="BorderBrush" Value="{StaticResource Gold}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <!-- Custom dark/yellow ScrollBar -->
    <Style x:Key="VtScrollThumb" TargetType="{x:Type Thumb}">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Thumb}">
            <Border x:Name="th" Background="#8a8104" Margin="2,0" CornerRadius="0"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="th" Property="Background" Value="#fcee0a"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="th" Property="Background" Value="#fcee0a"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="VtScrollPage" TargetType="{x:Type RepeatButton}">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type RepeatButton}">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Background" Value="#08090b"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ScrollBar}">
            <Grid Background="{TemplateBinding Background}">
              <Track Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Style="{StaticResource VtScrollPage}" Command="ScrollBar.PageUpCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource VtScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Style="{StaticResource VtScrollPage}" Command="ScrollBar.PageDownCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="{x:Type ScrollBar}">
                <Grid Background="{TemplateBinding Background}">
                  <Track Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Style="{StaticResource VtScrollPage}" Command="ScrollBar.PageLeftCommand"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Style="{StaticResource VtScrollThumb}"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Style="{StaticResource VtScrollPage}" Command="ScrollBar.PageRightCommand"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <!-- Outer corner brackets -->
    <Border Style="{StaticResource CornerTL}"/>
    <Border Style="{StaticResource CornerTR}"/>
    <Border Style="{StaticResource CornerBL}"/>
    <Border Style="{StaticResource CornerBR}"/>

    <ScrollViewer x:Name="RootScroll" Margin="14"
                  VerticalScrollBarVisibility="Auto"
                  HorizontalScrollBarVisibility="Disabled"
                  Focusable="False">
    <Grid x:Name="RootGrid">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*" MinHeight="240"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- HEADER -->
      <StackPanel Grid.Row="0" HorizontalAlignment="Center" Margin="0,12,0,18">
        <TextBlock Text="V O R T E R M"
                   FontFamily="JetBrains Mono, Cascadia Mono, Consolas"
                   FontSize="42" FontWeight="Thin"
                   Foreground="{StaticResource Gold}"
                   HorizontalAlignment="Center">
          <TextBlock.Effect>
            <DropShadowEffect Color="#fcee0a" BlurRadius="22" ShadowDepth="0" Opacity="0.7"/>
          </TextBlock.Effect>
        </TextBlock>
        <TextBlock Text="VII.2"
                   FontFamily="JetBrains Mono, Cascadia Mono, Consolas"
                   FontSize="12" Foreground="{StaticResource Muted}"
                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
      </StackPanel>

      <!-- PATH -->
      <Grid x:Name="StartupRow" Grid.Row="1" Margin="8,4,8,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="I / STARTUP"
                   Style="{StaticResource RomanLabel}"
                   VerticalAlignment="Center" Margin="0,0,18,0"
                   ToolTip="Directorio inicial de las nuevas pestanas de terminal"/>
        <TextBox x:Name="PathBox" Grid.Column="1"
                 ToolTip="Directorio inicial de las nuevas pestanas de terminal"/>
        <Button x:Name="BrowseBtn" Grid.Column="2" Content="BROWSE"
                Style="{StaticResource GhostButton}" Margin="14,0,0,0"
                Padding="22,7" FontSize="13"/>
      </Grid>

      <!-- CONFIG: 3 columns -->
      <Grid x:Name="ConfigRow" Grid.Row="2" Margin="8,8,8,8">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Grid Grid.Column="0" Margin="0,0,18,0">
          <StackPanel x:Name="SetupPanel">
            <TextBlock Text="II / SETUP" Style="{StaticResource RomanLabel}"/>
            <Border Style="{StaticResource SectionRule}"/>
            <TextBlock Text="APPS" Style="{StaticResource GroupLabel}"/>
            <UniformGrid Columns="2">
              <CheckBox x:Name="cb_vscode"  Content="vs code"        IsChecked="False" ToolTip="Visual Studio Code (winget Microsoft.VisualStudioCode)"/>
              <CheckBox x:Name="cb_node"    Content="node.js lts"    IsChecked="False"
                        ToolTip="Runtime para servidores MCP via npx (lo usa Claude Code Setup Guide). winget OpenJS.NodeJS.LTS"/>
              <CheckBox x:Name="cb_neovim"  Content="neovim"         IsChecked="False"/>
              <CheckBox x:Name="cb_7zip"    Content="7-zip"          IsChecked="False"/>
              <CheckBox x:Name="cb_github"  Content="github desktop" IsChecked="False"/>
              <CheckBox x:Name="cb_wsl"     Content="wsl"            IsChecked="False"
                        ToolTip="Instala WSL2 + Ubuntu. Puede requerir reinicio."/>
            </UniformGrid>
            <TextBlock Text="AI AGENTS" Style="{StaticResource GroupLabel}"/>
            <UniformGrid Columns="2">
              <CheckBox x:Name="cb_claude"  Content="claude code"    IsChecked="False"
                        ToolTip="CLI agente de Anthropic (winget Anthropic.ClaudeCode)"/>
              <CheckBox x:Name="cb_codex"   Content="codex cli"      IsChecked="False"
                        ToolTip="CLI agente de OpenAI (winget OpenAI.Codex)"/>
              <CheckBox x:Name="cb_antigrav" Content="antigravity"   IsChecked="False"
                        ToolTip="IDE agente de Google (winget Google.Antigravity)"/>
            </UniformGrid>
            <TextBlock Text="TERMINAL &amp; WORKSPACE" Style="{StaticResource GroupLabel}"/>
            <UniformGrid Columns="2">
              <CheckBox x:Name="cb_multipane" Content="multi-pane"   IsChecked="True"
                        ToolTip="m2 / m3 / m4 (2, 3 o 4 paneles), close N y /commands. Perfil oculto Vorterm Mosaic (negro, sin imagen).&#10;Atajos Ctrl+Shift+3 / B / Z solo si estan libres."/>
              <CheckBox x:Name="cb_lab"     Content="lab"            IsChecked="False"
                        ToolTip="Estructura de trabajo LAB (Azure, M365, Intune, seguridad...) con CLAUDE.md, plantillas y documentacion. Solo ficheros locales."/>
            </UniformGrid>
            <StackPanel x:Name="LabPanel" Visibility="Collapsed" Margin="26,2,0,6">
              <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,0,0,8"
                         Text="Crea LAB dentro de la carpeta elegida: areas Azure, M365, Outlook, Intune, seguridad, CloudOps, PowerShell, DevOps, docs, plantillas y CLAUDE.md (menos de 1 MB). Solo ficheros locales: sin admin, sin iniciar sesion, sin conectar a Azure ni M365. Nunca sobrescribe tus ficheros."/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="LabPathBox" Grid.Column="0" ToolTip="Carpeta donde se creara LAB"/>
                <Button x:Name="LabBrowseBtn" Grid.Column="1" Content="BROWSE"
                        Style="{StaticResource GhostButton}" Margin="10,0,0,0" Padding="14,5" FontSize="12"/>
              </Grid>
              <TextBlock x:Name="LabTarget" FontSize="12" Foreground="{StaticResource Muted}"
                         Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </StackPanel>
        </Grid>

        <Grid Grid.Column="1" Margin="0,0,18,0">
          <StackPanel>
            <TextBlock Text="III / RESET" Style="{StaticResource RomanLabel}"
                       Foreground="{StaticResource Danger}"/>
            <Border Style="{StaticResource SectionRule}" Background="{StaticResource Danger}"/>
            <CheckBox x:Name="cb_clean_profile" Content="powershell profiles" IsChecked="True"
                      ToolTip="Restaura backup Vorterm o mueve el perfil a .before-reset-*"/>
            <CheckBox x:Name="cb_clean_history" Content="psreadline history"  IsChecked="False"
                      ToolTip="Borra los ficheros *_history.txt de PSReadLine (sin copia)"/>
            <CheckBox x:Name="cb_clean_modules" Content="terminal modules"    IsChecked="True"
                      ToolTip="Quita las copias de usuario de Terminal-Icons, posh-git y PSReadLine + oh-my-posh.&#10;Ningun otro modulo se toca"/>
            <CheckBox x:Name="cb_clean_wt"      Content="windows terminal"    IsChecked="True"
                      ToolTip="Restaura settings.json al estado anterior a Vorterm (copia previa guardada).&#10;Quita el perfil Mosaic y los atajos Vorterm"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Column="2">
          <StackPanel x:Name="PathsPanel">
            <TextBlock Text="IV / PATHS" Style="{StaticResource RomanLabel}"/>
            <Border Style="{StaticResource SectionRule}"/>
          </StackPanel>
        </Grid>
      </Grid>

      <!-- CONSOLE -->
      <Grid Grid.Row="3" Margin="8,8,8,8">
        <Border Style="{StaticResource CornerTL}"/>
        <Border Style="{StaticResource CornerTR}"/>
        <Border Style="{StaticResource CornerBL}"/>
        <Border Style="{StaticResource CornerBR}"/>
        <Grid Margin="14,12,14,12">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0">
            <TextBlock Text="V / CONSOLE" Style="{StaticResource RomanLabel}"/>
            <Border Style="{StaticResource SectionRule}"/>
          </StackPanel>
          <RichTextBox x:Name="LogBox" Grid.Row="1" IsReadOnly="True" Background="Transparent"
                   BorderThickness="0"
                   FontFamily="JetBrains Mono, Cascadia Mono, Consolas"
                   FontSize="14" Foreground="#d9d9d9"
                   VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto"
                   IsUndoEnabled="False"
                   Padding="0,4,0,4"/>
        </Grid>
      </Grid>

      <!-- PROGRESS + PAUSE + STATUS -->
      <Grid Grid.Row="4" Margin="8,4,8,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="OptionsBtn" Grid.Column="3" Content="OPTIONS"
                Style="{StaticResource GhostButton}"
                Padding="18,6" FontSize="12" Margin="14,0,0,0"
                Visibility="Collapsed"
                ToolTip="Mostrar / ocultar las opciones (la consola usa todo el espacio mientras instala)"/>
        <ProgressBar x:Name="Progress" Height="2" Minimum="0" Maximum="100"
                     VerticalAlignment="Center">
          <ProgressBar.Effect>
            <DropShadowEffect Color="#fcee0a" BlurRadius="8" ShadowDepth="0" Opacity="0.7"/>
          </ProgressBar.Effect>
        </ProgressBar>
        <Button x:Name="PauseBtn" Grid.Column="1" Content="PAUSE"
                Style="{StaticResource GhostButton}"
                Padding="18,6" FontSize="12"
                Margin="14,0,0,0"
                Visibility="Collapsed"
                ToolTip="Suspende/reanuda los instaladores en curso"/>
        <TextBlock x:Name="StatusText" Grid.Column="2" Text="IDLE"
                   FontFamily="JetBrains Mono, Cascadia Mono, Consolas"
                   Margin="16,0,4,0" VerticalAlignment="Center"
                   Foreground="{StaticResource Muted}" FontSize="13"/>
      </Grid>

      <!-- ACTIONS -->
      <StackPanel Grid.Row="5" Orientation="Horizontal"
                  HorizontalAlignment="Center" Margin="0,16,0,8">
        <Button x:Name="ExitBtn"    Content="EXIT"    Style="{StaticResource GhostButton}"   Margin="0,0,14,0"/>
        <Button x:Name="ResetBtn"   Content="RESET"   Style="{StaticResource WarningButton}" Margin="0,0,14,0"
                ToolTip="Deshace la configuracion Vorterm (con confirmacion)"/>
        <Button x:Name="InstallBtn" Content="INSTALL" Style="{StaticResource PrimaryButton}"
                ToolTip="Instala stack completo: PS7, WT, Git, Nerd Font, oh-my-posh + tema"/>
      </StackPanel>
    </Grid>
    </ScrollViewer>
  </Grid>
</Window>
'@

# ------ Load XAML -------------------------------------------
try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    # INSTALAR.bat corre con -WindowStyle Hidden: sin esto, un fallo de XAML
    # seria totalmente silencioso (doble click y "no pasa nada").
    [System.Windows.MessageBox]::Show(
        "Vorterm no pudo construir la interfaz:`n`n$($_.Exception.Message)",
        'Vorterm - error', 'OK', 'Error') | Out-Null
    exit 1
}

# Barra de titulo oscura + titulo dorado (Win10 19041+ / Win11; en builds
# viejos el atributo se ignora sin error)
$window.Add_SourceInitialized({
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $on = 1
        [void][Vorterm.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)  # DWMWA_USE_IMMERSIVE_DARK_MODE
        [void][Vorterm.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4)  # id antiguo (builds < 19041)
        $caption = 0x00060505   # COLORREF BGR -> #050506 (fondo app), solo Win11
        [void][Vorterm.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$caption, 4) # DWMWA_CAPTION_COLOR
        $txt = 0x000AEEFC       # COLORREF BGR -> #fcee0a (dorado), solo Win11
        [void][Vorterm.Dwm]::DwmSetWindowAttribute($hwnd, 36, [ref]$txt, 4)     # DWMWA_TEXT_COLOR
    } catch {}
})

# Fit window to screen WorkArea, leaving small margin so taskbar / borders visible
$wa = [System.Windows.SystemParameters]::WorkArea
$marginX = 40
$marginY = 22
$window.Width  = [Math]::Min(1800, [Math]::Max(980, $wa.Width  - $marginX * 2))
$window.Height = [Math]::Min(1240, $wa.Height - $marginY * 2)
# Recenter dentro del area de trabajo (CenterScreen se calcula antes de este resize,
# asi que en pantallas chicas la ventana quedaba descentrada / con el borde inferior fuera)
$window.Left = $wa.Left + [Math]::Max(0, ($wa.Width  - $window.Width)  / 2)
$window.Top  = $wa.Top  + [Math]::Max(0, ($wa.Height - $window.Height) / 2)

$controls = @{}
foreach ($n in 'PathBox','BrowseBtn','LogBox','Progress','StatusText','ExitBtn','ResetBtn','InstallBtn','PauseBtn',
               'PathsPanel','RootScroll','RootGrid',
               'cb_vscode','cb_neovim','cb_7zip','cb_github','cb_wsl',
               'cb_claude','cb_codex','cb_antigrav','cb_node','cb_multipane','cb_lab',
               'SetupPanel','LabPanel','LabPathBox','LabBrowseBtn','LabTarget',
               'StartupRow','ConfigRow','OptionsBtn',
               'cb_clean_profile','cb_clean_wt','cb_clean_modules','cb_clean_history') {
    $controls[$n] = $window.FindName($n)
}

# Layout adaptativo: altura del grid = viewport (o el minimo si la ventana es
# mas chica -> scrollbar dorada). Altura FIJA, no MinHeight: si el grid pudiera
# crecer con el contenido, el log alargaria la pagina entera y la vista no
# seguiria al texto; asi el RichTextBox scrollea internamente y ScrollToEnd
# mantiene la consola pegada a la ultima linea.
function Update-RootHeight {
    $vh = $controls.RootScroll.ViewportHeight
    if ($vh -le 0) { return }
    # Minimo REAL medido: suma de las filas Auto (header, path, config con
    # PathsPanel incluido, progreso, botones) + minimo de la fila consola.
    # Nada de constantes: se adapta a DPI, ancho y contenido dinamico.
    $rows = $controls.RootGrid.RowDefinitions
    $autoSum = 0.0
    foreach ($i in 0,1,2,4,5) { $autoSum += $rows[$i].ActualHeight }
    $consoleMin = $rows[3].MinHeight
    $needed = $autoSum + $consoleMin
    $newH = [Math]::Max($vh, $needed)
    if ([Math]::Abs($controls.RootGrid.Height - $newH) -gt 0.5 -or
        [double]::IsNaN($controls.RootGrid.Height)) {
        $controls.RootGrid.Height = $newH
    }
}
$controls.RootScroll.Add_SizeChanged({ Update-RootHeight })
$controls.PathsPanel.Add_SizeChanged({ Update-RootHeight })
$controls.SetupPanel.Add_SizeChanged({ Update-RootHeight })
# Primer calculo cuando el layout inicial ya tiene medidas reales
$window.Add_ContentRendered({ Update-RootHeight })

# ------ Log document (RichTextBox con colores) ---------------
function Reset-LogDocument {
    $doc  = New-Object System.Windows.Documents.FlowDocument
    $doc.PageWidth = 2500   # sin word-wrap: scroll horizontal como una consola
    $para = New-Object System.Windows.Documents.Paragraph
    $para.Margin = [System.Windows.Thickness]::new(0)
    $doc.Blocks.Add($para)
    $controls.LogBox.Document = $doc
    $script:LogPara = $para
}
Reset-LogDocument

# ------ Populate Paths panel --------------------------------
function Open-PathTarget {
    param([string]$Target)
    if (-not $Target) { return }
    try {
        if (Test-Path $Target -PathType Leaf) {
            Start-Process explorer.exe -ArgumentList "/select,`"$Target`""
        } elseif (Test-Path $Target -PathType Container) {
            Start-Process explorer.exe -ArgumentList "`"$Target`""
        } else {
            $parent = Split-Path $Target -Parent
            if ($parent -and (Test-Path $parent)) {
                Start-Process explorer.exe -ArgumentList "`"$parent`""
            }
        }
    } catch {}
}

function Add-PathRow {
    param([string]$Label, [string]$Value)
    $exists = $false
    if ($Value) { $exists = Test-Path $Value -ErrorAction SilentlyContinue }
    $valueColor = if ($exists) { '#e8e8e8' } else { '#3a3b40' }

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $Label.ToUpper()
    $lbl.FontSize = 12
    $lbl.FontFamily = 'JetBrains Mono, Cascadia Mono, Consolas'
    $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#8a8104')
    $lbl.Margin = '0,10,0,3'
    [void]$controls.PathsPanel.Children.Add($lbl)

    $val = New-Object System.Windows.Controls.TextBlock
    $val.Text = $Value
    $val.FontSize = 13
    $val.FontFamily = 'JetBrains Mono, Cascadia Mono, Consolas'
    $val.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($valueColor)
    $val.TextWrapping = 'Wrap'
    $val.Cursor = 'Hand'
    $val.Tag = $Value
    $val.ToolTip = "Click para abrir en Explorer"
    $val.Add_MouseLeftButtonUp({ Open-PathTarget $this.Tag })
    $val.Add_MouseEnter({ $this.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#fcee0a') })
    $origColor = $valueColor
    $val.Add_MouseLeave({ $this.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($origColor) }.GetNewClosure())
    [void]$controls.PathsPanel.Children.Add($val)
}

$pwshExePath = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $pwshExePath) {
    foreach ($p in "$env:ProgramFiles\PowerShell\7\pwsh.exe",
                   "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
                   "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe") {
        if (Test-Path $p) { $pwshExePath = $p; break }
    }
}
if (-not $pwshExePath) { $pwshExePath = '(not installed)' }

$docsRoot = Get-DefaultDocs
Add-PathRow 'PS7 profile'        (Join-Path $docsRoot 'PowerShell\Microsoft.PowerShell_profile.ps1')
Add-PathRow 'PS7 modules'        (Join-Path $docsRoot 'PowerShell\Modules')
Add-PathRow 'Windows Terminal'   "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
Add-PathRow 'pwsh.exe'           $pwshExePath
Add-PathRow 'OMP themes folder'  (Join-Path $env:USERPROFILE '.poshthemes')
Add-PathRow 'OMP active theme'   (Join-Path $env:USERPROFILE ".poshthemes\$($script:ThemeFileName)")

$controls.PathBox.Text = $docsRoot

$controls.BrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Select startup directory'
    $dlg.SelectedPath        = $controls.PathBox.Text
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $controls.PathBox.Text = $dlg.SelectedPath
    }
})

# ------ LAB (opcional) -------------------------------------
function Update-LabTarget {
    $r = $controls.LabPathBox.Text.Trim().Trim('"')
    if ($r) { $controls.LabTarget.Text = "-> " + (Join-Path $r 'LAB') } else { $controls.LabTarget.Text = '' }
}
$controls.LabPathBox.Text = $docsRoot
Update-LabTarget
$controls.LabPathBox.Add_TextChanged({ Update-LabTarget })
$controls.cb_lab.Add_Checked({   $controls.LabPanel.Visibility = [System.Windows.Visibility]::Visible })
$controls.cb_lab.Add_Unchecked({ $controls.LabPanel.Visibility = [System.Windows.Visibility]::Collapsed })
$controls.LabBrowseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Carpeta donde se creara LAB'
    $dlg.SelectedPath        = $controls.LabPathBox.Text.Trim().Trim('"')
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $controls.LabPathBox.Text = $dlg.SelectedPath
    }
})

$controls.ExitBtn.Add_Click({ $window.Close() })

# Mientras instala/resetea, la consola ocupa la ventana: las opciones se pliegan y
# OPTIONS las vuelve a mostrar (o a ocultar).
function Set-OptionsVisible {
    param([bool]$Visible)
    $v = if ($Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $controls.StartupRow.Visibility = $v
    $controls.ConfigRow.Visibility  = $v
    $controls.OptionsBtn.Content    = $(if ($Visible) { 'CONSOLE' } else { 'OPTIONS' })
    $window.UpdateLayout()
    Update-RootHeight
}
$controls.OptionsBtn.Add_Click({
    Set-OptionsVisible ($controls.ConfigRow.Visibility -ne [System.Windows.Visibility]::Visible)
})

# ------ Finish dialog (negro / rojo, estilo terminal) ----------
# Se pasa como texto al runspace; el boton cierra via IsCancel (sin codigo).
$finishXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" SizeToContent="Height" Width="560"
        WindowStartupLocation="CenterOwner" Background="#050506" ShowInTaskbar="False" Topmost="True">
  <Border x:Name="FinBorder" BorderBrush="#e10024" BorderThickness="1" Padding="34,26,34,24">
    <StackPanel>
      <TextBlock Text="VORTERM // SYSTEM" Foreground="#6a6c70" FontSize="11"
                 FontFamily="JetBrains Mono, Cascadia Mono, Consolas"/>
      <TextBlock x:Name="FinTitle" Text="OPERATION COMPLETE" Foreground="#ff1a1a" FontSize="27" FontWeight="Bold"
                 FontFamily="JetBrains Mono, Cascadia Mono, Consolas" Margin="0,14,0,0">
        <TextBlock.Effect>
          <DropShadowEffect Color="#ff1a1a" BlurRadius="20" ShadowDepth="0" Opacity="0.9"/>
        </TextBlock.Effect>
      </TextBlock>
      <Border Height="1" Background="#2a2b2f" Margin="0,16,0,14"/>
      <TextBlock x:Name="FinBody" Foreground="#bdbdbd" FontSize="13" TextWrapping="Wrap"
                 FontFamily="JetBrains Mono, Cascadia Mono, Consolas"/>
      <Button x:Name="FinOk" Content="OK" IsCancel="True" IsDefault="True" HorizontalAlignment="Right"
              Margin="0,22,0,0" Padding="28,7" Foreground="#ff1a1a" Background="Transparent" BorderBrush="#e10024"
              FontFamily="JetBrains Mono, Cascadia Mono, Consolas" FontSize="13" Cursor="Hand">
        <Button.Template>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#2a0006"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Button.Template>
      </Button>
    </StackPanel>
  </Border>
</Window>
'@

# ------ Sync state ------------------------------------------
$sync = [hashtable]::Synchronized(@{
    FinishXaml  = $finishXaml
    NoGui       = $false
    Window      = $window
    LogBox      = $controls.LogBox
    LogPara     = $script:LogPara
    Progress    = $controls.Progress
    StatusText  = $controls.StatusText
    InstallBtn  = $controls.InstallBtn
    ResetBtn    = $controls.ResetBtn
    PauseBtn    = $controls.PauseBtn
    ActiveProcs = [System.Collections.ArrayList]::new()
    Paused      = $false
})

# Pause / Resume click handler (suspends winget child procs)
$controls.PauseBtn.Add_Click({
    if ($sync.Paused) {
        foreach ($p in @($sync.ActiveProcs)) {
            if ($p -and -not $p.HasExited) {
                try { [Vorterm.ProcCtl]::NtResumeProcess($p.Handle) | Out-Null } catch {}
            }
        }
        $sync.Paused = $false
        $controls.PauseBtn.Content = 'Pause'
        $controls.StatusText.Text = 'Running'
    } else {
        foreach ($p in @($sync.ActiveProcs)) {
            if ($p -and -not $p.HasExited) {
                try { [Vorterm.ProcCtl]::NtSuspendProcess($p.Handle) | Out-Null } catch {}
            }
        }
        $sync.Paused = $true
        $controls.PauseBtn.Content = 'Resume'
        $controls.StatusText.Text = 'Paused'
    }
})

# ------ Install action --------------------------------------
$controls.InstallBtn.Add_Click({
    $opts = @{
        Version      = $script:VortermVersion
        WorkDir      = $controls.PathBox.Text.Trim()
        Pwsh         = $true
        Git          = $true
        WT           = $true
        Font         = $true
        OMP          = $true
        PSRL         = $true
        Icons        = $true
        PoshGit      = $true
        WriteProfile = $true
        WTConfig     = $true
        Elevate      = $false
        VSCode       = $controls.cb_vscode.IsChecked
        Neovim       = $controls.cb_neovim.IsChecked
        SevenZip     = $controls.cb_7zip.IsChecked
        GitHubDesktop = $controls.cb_github.IsChecked
        WSL          = $controls.cb_wsl.IsChecked
        ClaudeCode   = $controls.cb_claude.IsChecked
        Codex        = $controls.cb_codex.IsChecked
        Antigravity  = $controls.cb_antigrav.IsChecked
        Node         = $controls.cb_node.IsChecked
        MultiPane    = $controls.cb_multipane.IsChecked
        Lab          = [bool]$controls.cb_lab.IsChecked
        LabRoot      = $controls.LabPathBox.Text.Trim().Trim('"')
        LabAdopt     = $false
        LabScript    = $script:LabScriptPath
        BgSrc        = $script:BgSrc
        Policy       = $true
        Verify       = $true
        DryRun       = $false
        LogFile      = New-VortermLogFile 'install'
        ThemeFile    = $script:ThemeFileName
        ThemeSrc     = $script:ThemeSrc
        ThemeJson    = $script:ThemeJson
    }

    if ([string]::IsNullOrWhiteSpace($opts.WorkDir)) {
        $opts.WorkDir = Get-DefaultDocs
    }

    # LAB: validar ruta, permisos y LAB existente ANTES de empezar a instalar nada
    if ($opts.Lab) {
        if (-not $opts.LabScript -or -not (Test-Path -LiteralPath $opts.LabScript)) {
            [System.Windows.MessageBox]::Show("No se encuentra lab\New-VortermLab.ps1 junto al instalador.`nDescarga el repositorio completo.",
                'Vorterm - LAB', 'OK', 'Error') | Out-Null
            return
        }
        try {
            $chk = & $opts.LabScript -Root $opts.LabRoot -ValidateOnly -PassThru
        } catch {
            [System.Windows.MessageBox]::Show("No se pudo validar la carpeta del LAB:`n$($_.Exception.Message)", 'Vorterm - LAB', 'OK', 'Error') | Out-Null
            return
        }
        if ($chk.Status -eq 'conflict') {
            $ans = [System.Windows.MessageBox]::Show(
                "$($chk.Errors -join "`n")`n`nAnadir SOLO los ficheros que falten? (no se sobrescribe ni se borra nada)",
                'Vorterm - LAB ya existe', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
            $opts.LabAdopt = $true
        } elseif ($chk.Status -ne 'ok') {
            [System.Windows.MessageBox]::Show(($chk.Errors -join "`n"), 'Vorterm - carpeta del LAB no valida', 'OK', 'Warning') | Out-Null
            return
        }
    }

    $controls.InstallBtn.IsEnabled = $false
    $controls.ResetBtn.IsEnabled   = $false
    $controls.OptionsBtn.Visibility = [System.Windows.Visibility]::Visible
    Set-OptionsVisible $false
    Reset-LogDocument
    $sync.LogPara = $script:LogPara
    $controls.Progress.Value = 0
    $controls.Progress.Foreground = $window.FindResource('Gold')
    try { $controls.Progress.Effect.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#fcee0a') } catch {}
    $controls.StatusText.Text = 'Running'
    $controls.StatusText.Foreground = [Windows.Media.Brushes]::Gold

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('opts', $opts)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($InstallLogic.ToString())
    [void]$ps.BeginInvoke()
})

# ------ Reset action ----------------------------------------
$controls.ResetBtn.Add_Click({
    $msg = @"
Deep terminal reset. Se hara lo siguiente (segun checkbox):

 - PowerShell profiles: quita SOLO el bloque Vorterm (tu contenido se conserva). Perfiles antiguos 7.0/7.1: se restaura el perfil que habia antes. Siempre deja copia .before-reset-*. Limpia la cache de init de oh-my-posh.
 - PSReadLine history (si lo marcas): borra %APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\*_history.txt
 - Terminal modules: quita las copias de usuario de Terminal-Icons, posh-git y PSReadLine que instala Vorterm, y el paquete winget de oh-my-posh.
 - Windows Terminal settings.json: vuelve al estado anterior a Vorterm (guardando el actual en .before-reset-*). Sin esa copia, quita solo lo de Vorterm: perfil Mosaic, atajos Vorterm, fondo/icono y claves del perfil PS7.

NUNCA se tocan: otros modulos (Az, Graph, EXO, Teams, PnP, Pester...), tu carpeta LAB, ni las apps PowerShell 7, Git, Windows Terminal y Nerd Font.

Continuar?
"@
    $confirm = [System.Windows.MessageBox]::Show(
        $msg,
        'Vorterm  -  Deep reset terminal',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $resetOpts = @{
        CleanProfile = $controls.cb_clean_profile.IsChecked
        CleanHistory = $controls.cb_clean_history.IsChecked
        CleanModules = $controls.cb_clean_modules.IsChecked
        CleanWT      = $controls.cb_clean_wt.IsChecked
        DryRun       = $false
    }

    $controls.InstallBtn.IsEnabled = $false
    $controls.ResetBtn.IsEnabled   = $false
    $controls.OptionsBtn.Visibility = [System.Windows.Visibility]::Visible
    Set-OptionsVisible $false
    Reset-LogDocument
    $sync.LogPara = $script:LogPara
    $controls.Progress.Value = 0
    $controls.Progress.Foreground = $window.FindResource('Gold')
    try { $controls.Progress.Effect.Color = [System.Windows.Media.ColorConverter]::ConvertFromString('#fcee0a') } catch {}
    $controls.StatusText.Text = 'Resetting'
    $controls.StatusText.Foreground = [Windows.Media.Brushes]::Gold

    $rs2 = [runspacefactory]::CreateRunspace()
    $rs2.ApartmentState = 'STA'
    $rs2.ThreadOptions  = 'ReuseThread'
    $rs2.Open()
    $rs2.SessionStateProxy.SetVariable('sync', $sync)
    $rs2.SessionStateProxy.SetVariable('opts', $resetOpts)

    $ps2 = [powershell]::Create()
    $ps2.Runspace = $rs2
    [void]$ps2.AddScript($ResetLogic.ToString())
    [void]$ps2.BeginInvoke()
})

# Arranca maximizada (el tamano calculado arriba queda para cuando se restaura)
$window.WindowState = [System.Windows.WindowState]::Maximized

try {
    [void]$window.ShowDialog()
} catch {
    [System.Windows.MessageBox]::Show(
        "Vorterm crash:`n`n$($_.Exception.Message)",
        'Vorterm - error', 'OK', 'Error') | Out-Null
    exit 1
}
