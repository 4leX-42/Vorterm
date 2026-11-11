# Installing, updating and recovering Vorterm

## Requirements

| Item | Notes |
| :-- | :-- |
| Windows 10 21H2+ or Windows 11 | Windows PowerShell 5.1 runs the installer; it installs PowerShell 7 itself |
| winget (App Installer) | Preinstalled on Windows 11. Without it packages are skipped and reported |
| Internet | winget packages, Nerd Font fallback, PowerShell Gallery modules, the profile icon (the background ships in `assets/`) |
| Admin rights | If your account is an administrator, Vorterm relaunches itself elevated (one UAC prompt). With a standard account it runs without admin on purpose (elevating with someone else's credentials would configure *their* profile): PowerShell 7 and oh-my-posh then fall back to the portable builds. `-NoElevate` skips the relaunch |

The LAB option needs none of the above: it only writes files.

## New machine

Fastest: one PowerShell command. `bootstrap.ps1` downloads the latest `main` to
`%LOCALAPPDATA%\Vorterm\app` and opens the window (the execution policy change only applies
to that PowerShell process):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; [Net.ServicePointManager]::SecurityProtocol=3072; $f="$env:TEMP\vorterm-bootstrap.ps1"; irm https://raw.githubusercontent.com/4leX-42/Vorterm/main/bootstrap.ps1 -OutFile $f; & $f
```

Manual alternative:

1. Download the repository (zip or `git clone`) and keep the folder structure: the
   installer needs `Mainthema.json` and the `lab\` folder next to it.
2. Double-click `INSTALAR.bat`.
3. Tick the optional components, press **INSTALL** and read the console. Everything is
   also written to `%LOCALAPPDATA%\Vorterm\logs\install-<date>.log`.
4. Restart Windows Terminal.

### What the installer changes

| Area | Change | How it is undone |
| :-- | :-- | :-- |
| Packages | winget: PowerShell 7, Git, Windows Terminal, JetBrainsMono Nerd Font, oh-my-posh and the optional apps you tick. Already installed apps are skipped | uninstall from Windows Settings |
| Execution policy | `CurrentUser` -> `RemoteSigned`, only if it was Restricted/AllSigned/undefined and no GPO controls it | `Set-ExecutionPolicy -Scope CurrentUser Undefined` |
| PowerShell Gallery | NuGet provider, PSGallery trusted, Terminal-Icons, posh-git, PSReadLine (only if older than 2.3.6) | Reset (modules) |
| Profiles | One managed block in the PowerShell 7 and 5.1 profiles; everything else in the file is kept | Reset (profiles) |
| Theme | `~\.poshthemes\Mainthema.json`, `POSH_THEMES_PATH` | delete the folder / variable |
| Windows Terminal | Font and look of the PowerShell 7 profile (background and icon only if it has none), default profile, hidden "Vorterm Mosaic" profile, three shortcuts only if those keys are free. Session restore: `firstWindowPreference` (persisted layout) and `windowingBehavior: useAnyExisting`, only while they are at their defaults | Reset (Windows Terminal) |
| Session restore | `%LOCALAPPDATA%\Vorterm\restore` (two scripts) and three hooks in `~\.claude\settings.json` and `~\.claude2\settings.json` when those files exist. Skipped when you already load your own `term-restore.ps1` | Reset (profiles) |
| Claude Code config (optional) | `~\.claude\settings.json` and `~\.claude2\settings.json` (`permissions.defaultMode`, `skipDangerousModePermissionPrompt`, `permissions.deny`, `statusLine`; other keys kept, backup `.vorterm-bak-*`), plugins and MCP servers through the Claude Code Setup Guide engine (downloaded to `%LOCALAPPDATA%\Vorterm\claude-setup`), `claude2` launcher in the PowerShell profile, `Documents\claude-lab` | `claude plugin uninstall`, remove the keys; Reset does not touch it |
| LAB (optional) | `<folder>\LAB` | delete the folder; Reset never touches it |

Backups: the first time Vorterm changes a profile or `settings.json` it saves
`<file>.vorterm-original`; every later write keeps a rotating `<file>.vorterm-bak-<date>`
(last 5). Files are only rewritten when something actually changes.

## Unattended install

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\setup_terminal.ps1 -NoGui [options]
```

| Option | Meaning |
| :-- | :-- |
| `-DryRun` | Show what would happen, change nothing |
| `-WorkDir <path>` | Start folder of new terminal tabs (default: Documents) |
| `-Node` | Install Node.js LTS (needed by MCP servers in Claude Code) |
| `-ClaudeCode` | Install Claude Code (winget) |
| `-VSCode` | Install Visual Studio Code |
| `-NoMultiPane` | Skip m2/m3/m4, the Mosaic profile and its shortcuts |
| `-NoRestore` | Skip session restore (panes and Claude Code sessions coming back after a reboot) |
| `-ClaudeConfig` | Claude Code config: `bypassPermissions` by default (always), deny rules, essentials plugins and MCP servers, second profile, status line, `claude-lab` folder. Implies `-ClaudeCode -Node` |
| `-LabRoot <path>` | Create the LAB in `<path>\LAB` |
| `-LabAdopt` | Use an existing `LAB` folder that Vorterm did not create (adds missing files only) |
| `-Reset` | Undo the Vorterm configuration (profiles, modules, Windows Terminal) |
| `-NoElevate` | Do not relaunch elevated (by default an administrator account gets one UAC prompt) |

Exit code: `0` all green, `1` finished with warnings (see the log).

## Updating

Download the new version and run it again. The managed profile block, the theme and the
Windows Terminal keys are refreshed; packages already installed are left as they are
(update them with `winget upgrade`). A LAB created earlier is updated the same way as
running the LAB generator again (see [LAB.md](LAB.md)).

Profiles written by Vorterm 7.0/7.1 (whole file generated by Vorterm) are converted to the
managed block automatically.

## With Claude Code Setup Guide

Install Vorterm first, then the [Claude Code Setup Guide](https://github.com/4leX-42/ClaudeCode_SETUP):

- Vorterm provides PowerShell 7, Git, Node.js (tick it), the execution policy and the
  terminal; the Setup Guide checks for them and does not install them again.
- Both edit the PowerShell 7 profile, each in its own marked block, so running either one
  again (or Vorterm's Reset) does not remove the other's lines.
- If you tick **claude code** in Vorterm, the Setup Guide reuses that installation as long as
  it meets its minimum version.

## Recovery

| Problem | Fix |
| :-- | :-- |
| Red errors when a terminal opens | Read `%LOCALAPPDATA%\Vorterm\logs\`; run INSTALAR.bat again; the smoke test at the end shows the first errors |
| Profile broken after manual edits | The managed block is rewritten on the next install; or restore `<profile>.vorterm-bak-<date>` |
| Windows Terminal settings broken | Restore `settings.json.vorterm-bak-<date>` or `settings.json.vorterm-original` from the same folder |
| Boxes instead of icons | WT Settings -> PowerShell -> Appearance -> Font -> JetBrainsMono Nerd Font |
| "running scripts is disabled" | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Want everything back as before | Reset (button or `-NoGui -Reset`), then uninstall the apps you do not want |
