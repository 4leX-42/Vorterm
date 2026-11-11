# Changelog

## 7.3 - 2026-11-11

### Added
- **Session restore** (on by default, `-NoRestore` to skip): after a reboot, crash or forced
  close, Windows Terminal reopens its panes, each goes back to its folder and resumes the
  Claude Code session it had (`~\.claude` and `~\.claude2`). Scripts in `restore\`, copied to
  `%LOCALAPPDATA%\Vorterm\restore`; Claude Code hooks SessionStart / UserPromptSubmit /
  SessionEnd only in profiles that already exist; Windows Terminal `firstWindowPreference`
  (persistedLayoutAndContent on 1.25+, persistedWindowLayout before) and
  `windowingBehavior: useAnyExisting`, only while at their defaults. A user's own
  `term-restore.ps1` or hooks are detected and left alone.
- **Motion** in the window, in the style of PastDow: sections rise in on open, a light runs
  along the progress hairline while something works, the status breathes, the bar glows once
  on finish, the finish dialog fades in, and the window minimises into its taskbar button
  and pours back out (genie). Off when Windows animations are off or `VORTERM_NO_MOTION=1`.

### Changed
- `m2 -Claude` panes brought back by session restore resume their session instead of
  starting a new Claude.
- Reset also removes the session restore scripts and Vorterm's Claude Code hooks.
- `tests/Test-VortermStatic.ps1`: gitleaks output no longer stops the run on PowerShell 5.1.

### Fixed
- Install hung forever without Internet (no DNS, proxy): when the NuGet provider cannot be
  installed, PowerShell asked "install NuGet? [Y/N]" with nobody to answer. Now PowerShell
  Gallery modules are skipped with a warning and the install goes on.

## 7.2 - 2026-10-17

### Added
- **Lab** (optional): checkbox, folder picker and unattended `-LabRoot`.
  Separate generator `lab/New-VortermLab.ps1` with a manifest-driven template; validates
  the path, permissions and an existing LAB before writing; never overwrites or deletes.
- **Multi-pane**: `m2` / `m3` / `m4` (`-Rows`, `-Claude`), `close N`, `/commands`, hidden
  "Vorterm Mosaic" profile (black, no background image), shortcuts Ctrl+Shift+3 / B / Z
  added only when those keys are free.
- **Node.js LTS** option (MCP servers for Claude Code).
- Unattended options: `-WorkDir`, `-Node`, `-ClaudeCode`, `-VSCode`, `-NoMultiPane`,
  `-LabRoot`, `-LabAdopt`, `-Reset`; exit code 1 on warnings.
- Install log in `%LOCALAPPDATA%\Vorterm\logs`.
- Tests: `tests/Test-VortermStatic.ps1`, `tests/Test-VortermLab.ps1`,
  `tests/Test-VortermInstall.ps1` (disposable VM only).
- Cross-links with the companion repository Claude Code Setup Guide.

### Changed
- The PowerShell profile is no longer overwritten: Vorterm manages only its block between
  `# >>> vorterm >>>` markers and keeps everything else. 7.0/7.1 profiles are migrated.
- Windows Terminal: only the real PowerShell 7 profile is patched (not every profile that
  mentions pwsh); background and icon are set only when the profile has none; the file is
  written only when something changes.
- Backups: one `.vorterm-original` plus rotating `.vorterm-bak-*` (last 5); user `.bak-*`
  files are never touched.
- PSReadLine is installed only when PowerShell 7 does not already have 2.3.6 or newer
  (no downgrade of the 2.4.x bundled with PowerShell 7.5+).
- Execution policy check reads CurrentUser / LocalMachine / GPO instead of the process
  scope set by INSTALAR.bat.
- Module and profile paths follow OneDrive "Known Folder Move".
- Reset only removes what Vorterm added and always keeps a `.before-reset-*` copy; the
  history option is now off by default.

### Fixed
- PowerShell 7 and oh-my-posh not installed when winget's MSI fails (Windows Installer
  disabled, `0x80070422`, or no admin rights): fallback to the official portable builds in
  the user profile (SHA256 verified against the release checksums) + user PATH.
- Red `Import-Clixml: Root element is missing` when several terminals start together
  (Terminal-Icons rewrites its XML on every import; the import is now serialized).
- Embedded fallback theme had two missing icons; the installer is pure ASCII again.
