<table align="center">
<tr>
<td width="340" align="center">
<img width="300" alt="Vorterm logo" src="https://github.com/user-attachments/assets/a982c6b2-9dc2-4f65-a131-98291bb14226" />
</td>
<td valign="middle">

### VORTERM 7.2

**From clean Windows to modern dev shell**
*one click*

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.x-5391FE?logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows&logoColor=white)
![winget](https://img.shields.io/badge/winget-silent-FCEE0A?logoColor=black)
![license](https://img.shields.io/badge/license-MIT-1a1a1a)

[Install](#-install) · [Stack](#-stack) · [Multi-pane](#-multi-pane) · [Lab](#-lab-optional) · [Claude Code](#-claude-code-companion) · [Reset](#-reset)

</td>
</tr>
</table>

---

## ⚡ Install

One command in PowerShell: downloads the latest Vorterm and opens it. Nothing is installed until you press **INSTALL**.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; [Net.ServicePointManager]::SecurityProtocol=3072; $f="$env:TEMP\vorterm-bootstrap.ps1"; irm https://raw.githubusercontent.com/4leX-42/Vorterm7.0/main/bootstrap.ps1 -OutFile $f; & $f
```

Or download the repository and double-click:

```bat
INSTALAR.bat
```

Re-running either is safe: anything already in place is left alone.

Unattended (no window), for new machines or scripts:

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\setup_terminal.ps1 -NoGui
powershell -ExecutionPolicy Bypass -STA -File .\setup_terminal.ps1 -NoGui -Node -ClaudeCode -LabRoot "$env:USERPROFILE\Desktop"
```

Full options, updates and recovery: [docs/INSTALL.md](docs/INSTALL.md).

<br/>

<div align="center">
  <img src="assets/terminal.png" alt="PowerShell 7 with oh-my-posh + Nerd Font" width="880"/>
  <br/>
  <sub><i>PowerShell 7 · oh-my-posh · Nerd Font · Terminal-Icons</i></sub>
</div>

<br/>

---

## 📦 Stack

> Silent · sequential &amp; retry-safe · winget-powered · idempotent

<table align="center">
<tr>
<td valign="top" width="50%">

**Core**

<sub>
PowerShell 7<br/>
Windows Terminal<br/>
Git
</sub>

</td>
<td valign="top" width="50%">

**Shell experience**

<sub>
oh-my-posh + <code>Mainthema</code> (bundled, offline)<br/>
JetBrainsMono Nerd Font<br/>
PSReadLine · Terminal-Icons · posh-git
</sub>

</td>
</tr>
</table>

Your PowerShell profile keeps everything you wrote: Vorterm only manages its own block
between `# >>> vorterm >>>` and `# <<< vorterm <<<`.

---

## 🧩 Optional

`VS Code` · `Neovim` · `7-Zip` · `GitHub Desktop` · `WSL` · `Node.js LTS` · `Claude Code` · `Codex CLI` · `Antigravity`

---

## 🪟 Multi-pane

One Windows Terminal window, several panes of a hidden black profile (no background image,
so text stays readable). On by default.

| Command | What it does |
| :-- | :-- |
| `m2` / `m3` / `m4` | 2 or 3 columns, or a 2x2 grid, maximized |
| `-Rows` | stack the panes as rows (vertical monitor) |
| `-Claude` | start Claude Code in every pane |
| `close 2` | close pane 2 from any pane (`close 2 3` for several) |
| `/commands` | cheat sheet in the terminal |
| `Ctrl+Shift+3 / B / Z` | split in 3 · type in all panes · zoom pane (only if the keys were free) |

---

## 🧪 Lab (optional)

Tick **lab**, choose a folder, and Vorterm creates `<folder>\LAB`: a
ready-to-use working structure for Azure, Microsoft 365, Outlook/Exchange, Intune,
security, Power Automate, CloudOps, PowerShell and DevOps work, with a `CLAUDE.md`,
area rules, templates (runbook, change plan, incident, postmortem, project, script, KQL)
and fictitious examples.

- Local files only: no admin, no sign-in, no connection to Azure or Microsoft 365.
- Never overwrites your files; re-running adds what is missing and refreshes only files
  you have not edited. An existing folder that Vorterm did not create is never touched
  unless you choose to add the missing files.
- Also works on its own: `lab\New-VortermLab.ps1 -Root D:\Work`.

Details: [docs/LAB.md](docs/LAB.md).

---

## 🤖 Claude Code companion

**[Claude Code Setup Guide](https://github.com/4leX-42/ClaudeCode_SETUP)** is the
official complement: Vorterm prepares the terminal (shell, fonts, Git, Node.js, execution
policy, profile); the Setup Guide configures Claude Code on top of it (plugins, MCP
servers, permissions, status line, second profile).

1. Vorterm (tick **node.js lts** and, if you like, **claude code**).
2. Claude Code Setup Guide: `pwsh -File install.ps1`.

Each works on its own; together they never edit the same lines (the Setup Guide writes
its own marked block in the profile, outside Vorterm's).

---

## 🔄 Reset

One click. Removes only what Vorterm added: its profile block (your own lines stay), the
user copies of its modules, the Mosaic profile and its shortcuts, and returns Windows
Terminal settings to the state before Vorterm. A `.before-reset-*` copy is kept every time.
Your LAB folder is never touched.

---

<div align="center">

**Build · Ship · Forget**

<sub>MIT © Vorterm · [Changelog](CHANGELOG.md)</sub>

</div>
