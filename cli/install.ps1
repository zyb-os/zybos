#Requires -Version 5.1
# install.ps1 — ZybOS CLI installer for Windows.
#
# One-line install (downloads everything from GitHub):
#   irm https://raw.githubusercontent.com/ZybOS/agent-orchestrator/main/cli/install.ps1 | iex
#
# Or from a local clone:
#   powershell -ExecutionPolicy Bypass -File cli\install.ps1
#
# Options:
#   -InstallDir PATH    Installation directory (default: %LOCALAPPDATA%\ZybOS)
#   -GitHubRepo REPO    GitHub org/repo (default: biome-os/agent-orchestrator)
#   -Branch NAME        Branch or tag to download (default: main)
#   -NoService          Skip Windows Task Scheduler service registration
#   -Agents "a b"       Space-separated subset of agents to install
#   -AllAgents          Install every available agent
#   -Python PATH        Explicit python.exe to use
#   -Uninstall          Remove a previous installation
#
[CmdletBinding()]
param(
    [string]$InstallDir  = "$env:LOCALAPPDATA\ZybOS",
    [string]$GitHubRepo  = "ZybOS/agent-orchestrator",
    [string]$Branch      = "main",
    [switch]$NoService,
    [string]$Agents      = "",
    [switch]$AllAgents,
    [string]$Python      = "",
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Info  { param($msg) Write-Host "  > $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "  [x]  $msg" -ForegroundColor Red; exit 1 }

# ── Agent lists ───────────────────────────────────────────────────────────────
$CoreAgents = @(
    "agent-orchestrator",
    "task-planner-agent",
    "task-executor-agent",
    "task-scheduler-agent",
    "browser-agent",
    "slack-connector-agent",
    "gmail-agent",
    "summarize-agent",
    "filesystem-agent",
    "code-execution-agent",
    "self-heal-agent",
    "workflow-validator-agent",
    "skill-loader-agent",
    "skill-writer-agent",
    "telegram-agent"
)

$AllAgentList = $CoreAgents + @(
    "whatsapp-connector-agent",
    "serper-search-agent",
    "document-agent",
    "google-docs-agent",
    "research-agent",
    "avatar-agent"
)

# ── Uninstall ─────────────────────────────────────────────────────────────────
if ($Uninstall) {
    $confirm = Read-Host "Remove $InstallDir? This cannot be undone. [y/N]"
    if ($confirm -notmatch '^[yY]$') { Write-Host "Cancelled."; exit 0 }

    # Stop any running processes via PID files
    $runDir = Join-Path $InstallDir "run"
    if (Test-Path $runDir) {
        Get-ChildItem "$runDir\*.pid" | ForEach-Object {
            $pid = [int](Get-Content $_.FullName -ErrorAction SilentlyContinue)
            if ($pid) {
                try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    # Remove scheduled task if registered
    try { Unregister-ScheduledTask -TaskName "ZybOS" -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    # Remove install dir
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }

    # Remove from PATH
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $binDir   = Join-Path $InstallDir "bin"
    if ($userPath -like "*$binDir*") {
        $newPath = ($userPath -split ";" | Where-Object { $_ -ne $binDir }) -join ";"
        [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    }

    Write-Ok "ZybOS has been removed."
    exit 0
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "ZybOS — CLI Installer (Windows)" -ForegroundColor White
Write-Host "Install directory: $InstallDir" -ForegroundColor Gray
Write-Host ""

# ── 1. Find Python ─────────────────────────────────────────────────────────────
Write-Info "Checking Python..."
if ($Python -eq "") {
    foreach ($candidate in @("python3.12", "python3.11", "python3.10", "python3", "python")) {
        try {
            $found = (Get-Command $candidate -ErrorAction SilentlyContinue)?.Source
            if ($found) { $Python = $found; break }
        } catch {}
    }
}
if ($Python -eq "") { Write-Fail "Python 3.10+ not found. Install Python from python.org and re-run." }

$verStr = & $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>&1
$parts  = $verStr -split "\."
if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 10)) {
    Write-Fail "Python 3.10+ required. Found: $verStr"
}
Write-Ok "Python $verStr at $Python"

# ── 2. Obtain source ──────────────────────────────────────────────────────────
# Priority: (a) local repo clone  (b) git clone  (c) tarball download
Write-Info "Obtaining source code..."
$RepoRoot = ""

# (a) Running from inside a local clone?
try {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidate = (Resolve-Path (Join-Path $ScriptDir "..")).Path
    if (Test-Path (Join-Path $candidate "agent-orchestrator\main.py")) {
        $RepoRoot = $candidate
        Write-Ok "Using local repository at $RepoRoot"
    }
} catch {}

if ($RepoRoot -eq "") {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $tmpRepo = Join-Path $InstallDir ".repo-download"
    Remove-Item $tmpRepo -Recurse -Force -ErrorAction SilentlyContinue

    # (b) Try git clone
    $gitExe = (Get-Command git -ErrorAction SilentlyContinue)?.Source
    if ($gitExe) {
        Write-Info "Cloning $GitHubRepo ($Branch) via git..."
        try {
            & $gitExe clone --depth 1 --branch $Branch `
                "https://github.com/$GitHubRepo.git" $tmpRepo 2>&1 | Out-Null
            if (Test-Path (Join-Path $tmpRepo "agent-orchestrator\main.py")) {
                $RepoRoot = $tmpRepo
                Write-Ok "Repository cloned"
            }
        } catch { Write-Warn "git clone failed, falling back to tarball..." }
    }

    # (c) Tarball via Invoke-WebRequest
    if ($RepoRoot -eq "") {
        $tarUrl  = "https://github.com/$GitHubRepo/archive/refs/heads/$Branch.zip"
        $tmpZip  = Join-Path $InstallDir ".source.zip"
        Write-Info "Downloading source from GitHub ($tarUrl)..."
        try {
            Invoke-WebRequest -Uri $tarUrl -OutFile $tmpZip -UseBasicParsing
            $extractDir = Join-Path $InstallDir ".repo-extract"
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $tmpZip -DestinationPath $extractDir -Force
            # GitHub zip contains a single top-level directory like "repo-main/"
            $inner = Get-ChildItem $extractDir -Directory | Select-Object -First 1
            if ($inner -and (Test-Path (Join-Path $inner.FullName "agent-orchestrator\main.py"))) {
                $RepoRoot = $inner.FullName
                Write-Ok "Source downloaded and extracted"
            }
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Fail "Could not download source: $_. Install git or check your internet connection."
        }
    }
}

if ($RepoRoot -eq "" -or -not (Test-Path (Join-Path $RepoRoot "agent-orchestrator\main.py"))) {
    Write-Fail "agent-orchestrator source not found. Check --GitHubRepo / --Branch."
}
Write-Ok "Source root: $RepoRoot"

# CLI scripts come from the downloaded source too
$CliSrcDir = Join-Path $RepoRoot "cli"

# ── 3. Resolve agent list ─────────────────────────────────────────────────────
if ($AllAgents)       { $AgentList = $AllAgentList }
elseif ($Agents -ne "") { $AgentList = $Agents -split "\s+" }
else                   { $AgentList = $CoreAgents }

$ValidAgents = @()
foreach ($a in $AgentList) {
    if (Test-Path (Join-Path $RepoRoot $a)) {
        $ValidAgents += $a
    } else {
        Write-Warn "Agent not found in repo, skipping: $a"
    }
}
$AgentList = $ValidAgents

# ── 4. Create directories ─────────────────────────────────────────────────────
Write-Info "Creating directories..."
$SrcDir    = Join-Path $InstallDir "src"
$VenvDir   = Join-Path $InstallDir "venvs"
$LogDir    = Join-Path $InstallDir "logs"
$RunDir    = Join-Path $InstallDir "run"
$BinDir    = Join-Path $InstallDir "bin"
foreach ($dir in @($SrcDir, $VenvDir, $LogDir, $RunDir, $BinDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# ── 5. Copy source ────────────────────────────────────────────────────────────
Write-Info "Copying source files..."
$ExcludeDirs = @(".venv", "venv", "env", "__pycache__", ".git", "node_modules", "dist", "build", "data")
foreach ($agent in $AgentList) {
    $src  = Join-Path $RepoRoot $agent
    $dest = Join-Path $SrcDir $agent
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $src $dest -Recurse -Force

    # Prune excluded dirs from the copy
    foreach ($excl in $ExcludeDirs) {
        $exclPath = Join-Path $dest $excl
        if (Test-Path $exclPath) { Remove-Item $exclPath -Recurse -Force }
    }
}
Write-Ok "Source copied"

# ── 6. Create virtual environments ───────────────────────────────────────────
Write-Info "Creating virtual environments..."
$Total = $AgentList.Count
$Idx   = 0
foreach ($agent in $AgentList) {
    $Idx++
    Write-Host "  [$Idx/$Total] $agent..." -NoNewline
    $agentVenv = Join-Path $VenvDir $agent
    $agentSrc  = Join-Path $SrcDir $agent
    $req       = Join-Path $agentSrc "requirements.txt"

    if (-not (Test-Path $agentVenv)) {
        & $Python -m venv $agentVenv 2>&1 | Out-Null
    }
    $pip = Join-Path $agentVenv "Scripts\pip.exe"
    if (Test-Path $req) {
        & $pip install --quiet --upgrade pip 2>&1 | Out-Null
        & $pip install --quiet -r $req 2>&1 | Out-Null
        Write-Host " ok" -ForegroundColor Green
    } else {
        Write-Host " (no requirements.txt)" -ForegroundColor Yellow
    }
}
Write-Ok "Virtual environments ready"

# ── 7. Write config file ──────────────────────────────────────────────────────
Write-Info "Writing configuration..."
$ConfigFile = Join-Path $InstallDir "config.env"
if (Test-Path $ConfigFile) {
    Copy-Item $ConfigFile "$ConfigFile.bak" -Force
    Write-Warn "Existing config backed up to $ConfigFile.bak"
}
@"
# ZybOS — Installation config
INSTALL_DIR=$InstallDir
SRC_DIR=$SrcDir
VENV_DIR=$VenvDir
LOG_DIR=$LogDir
RUN_DIR=$RunDir
ORCHESTRATOR_URL=http://localhost:8000
ORCHESTRATOR_HOST=0.0.0.0
ORCHESTRATOR_PORT=8000
LOG_LEVEL=INFO
GITHUB_REPO=$GitHubRepo
GITHUB_BRANCH=$Branch
ENABLED_AGENTS=
"@ | Set-Content $ConfigFile
Write-Ok "Config: $ConfigFile"

# ── 8. Write manifest ─────────────────────────────────────────────────────────
$ManifestFile = Join-Path $InstallDir "agents.txt"
$AgentList | Set-Content $ManifestFile

# ── 9. Install CLI script ─────────────────────────────────────────────────────
Write-Info "Installing CLI command..."
$CliScript = Join-Path $BinDir "zybos.ps1"
# Use CLI script from the downloaded/local source
$CliSrcPs1 = Join-Path $CliSrcDir "zybos.ps1"
if (Test-Path $CliSrcPs1) {
    Copy-Item $CliSrcPs1 $CliScript -Force
} else {
    # Generate wrapper pointing to the main CLI generated below
    @"
# Auto-generated wrapper
`$env:AGENTORCH_INSTALL_DIR = '$InstallDir'
& (Join-Path '$InstallDir' 'bin\zybos_main.ps1') @args
"@ | Set-Content $CliScript
}

# Also write a .bat launcher so it works from cmd.exe without specifying pwsh
$CliBat = Join-Path $BinDir "zybos.bat"
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0zybos.ps1" %*
"@ | Set-Content $CliBat

Write-Ok "CLI command: $CliScript"

# ── 10. Add BinDir to user PATH ───────────────────────────────────────────────
$userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($userPath -notlike "*$BinDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$BinDir;$userPath", "User")
    Write-Warn "Added $BinDir to your PATH. Open a new terminal to use 'zybos'."
} else {
    Write-Ok "PATH already includes $BinDir"
}

# ── 11. Generate zybos.ps1 (main CLI) ────────────────────────────
$MainCli = Join-Path $BinDir "zybos_main.ps1"
@'
#Requires -Version 5.1
# zybos_main.ps1 — Windows CLI for ZybOS
param([Parameter(Position=0)][string]$Command = "help",
      [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)

$INSTALL_DIR = if ($env:AGENTORCH_INSTALL_DIR) { $env:AGENTORCH_INSTALL_DIR } else { "$env:LOCALAPPDATA\ZybOS" }
$ConfigFile  = "$INSTALL_DIR\config.env"
$SrcDir      = "$INSTALL_DIR\src"
$VenvDir     = "$INSTALL_DIR\venvs"
$LogDir      = "$INSTALL_DIR\logs"
$RunDir      = "$INSTALL_DIR\run"
$Manifest    = "$INSTALL_DIR\agents.txt"
$OrchestratorUrl = "http://localhost:8000"

# Source config
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match "^([A-Z_]+)=(.*)$") {
            Set-Variable -Name $Matches[1] -Value $Matches[2] -Scope Script -ErrorAction SilentlyContinue
        }
    }
}

function Get-Agents {
    if (Test-Path $Manifest) { Get-Content $Manifest }
    elseif (Test-Path $SrcDir) { Get-ChildItem $SrcDir -Directory | Select-Object -ExpandProperty Name }
}
function Get-PidFile  { param($a) "$RunDir\$a.pid" }
function Get-LogFile  { param($a) "$LogDir\$a.log" }
function Test-Running { param($a)
    $pf = Get-PidFile $a
    if (Test-Path $pf) {
        $p = [int](Get-Content $pf -ErrorAction SilentlyContinue)
        try { $proc = Get-Process -Id $p -ErrorAction Stop; return $true } catch {}
        Remove-Item $pf -Force -ErrorAction SilentlyContinue
    }
    return $false
}
function Get-PythonFor { param($a)
    $vp = "$VenvDir\$a\Scripts\python.exe"
    if (Test-Path $vp) { $vp } else { "python" }
}

function Start-Agent { param($agent)
    $src = "$SrcDir\$agent"
    $pf  = Get-PidFile $agent
    if (Test-Running $agent) { Write-Host "  [!] $agent already running"; return }
    if (-not (Test-Path "$src\main.py")) { Write-Host "  [!] $agent: no main.py, skipping"; return }
    $py   = Get-PythonFor $agent
    $log  = Get-LogFile $agent
    $args = if ($agent -ne "agent-orchestrator") { @("main.py", "--orchestrator-url", $OrchestratorUrl) } else { @("main.py") }
    $proc = Start-Process -FilePath $py -ArgumentList $args `
                          -WorkingDirectory $src `
                          -RedirectStandardOutput $log `
                          -RedirectStandardError  $log `
                          -WindowStyle Hidden -PassThru
    $proc.Id | Set-Content $pf
    Write-Host "  [OK] Started $agent (pid $($proc.Id))"
}

function Stop-Agent { param($agent)
    $pf = Get-PidFile $agent
    if (-not (Test-Running $agent)) { Write-Host "  [!] $agent not running"; return }
    $p = [int](Get-Content $pf)
    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Remove-Item $pf -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Stopped $agent"
}

switch ($Command.ToLower()) {
    "start" {
        $target = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
        if ($target) { Start-Agent $target }
        else {
            Start-Agent "agent-orchestrator"; Start-Sleep 2
            Get-Agents | Where-Object { $_ -ne "agent-orchestrator" } | ForEach-Object { Start-Agent $_ }
        }
    }
    "stop" {
        $target = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
        if ($target) { Stop-Agent $target }
        else {
            Get-Agents | Where-Object { $_ -ne "agent-orchestrator" } | ForEach-Object { if (Test-Running $_) { Stop-Agent $_ } }
            if (Test-Running "agent-orchestrator") { Stop-Agent "agent-orchestrator" }
        }
    }
    "restart" {
        $target = if ($Rest.Count -gt 0) { $Rest[0] } else { "" }
        if ($target) { Stop-Agent $target; Start-Sleep 1; Start-Agent $target }
        else { & $MyInvocation.MyCommand.Path stop; Start-Sleep 1; & $MyInvocation.MyCommand.Path start }
    }
    "status" {
        Write-Host ("{0,-40} {1,-10} {2}" -f "AGENT","STATUS","PID")
        Write-Host ("-" * 60)
        Get-Agents | ForEach-Object {
            if (Test-Running $_) {
                $pid_ = Get-Content (Get-PidFile $_)
                Write-Host ("{0,-40} " -f $_) -NoNewline
                Write-Host ("{0,-10}" -f "running") -ForegroundColor Green -NoNewline
                Write-Host " $pid_"
            } else {
                Write-Host ("{0,-40} " -f $_) -NoNewline
                Write-Host "stopped" -ForegroundColor Red
            }
        }
    }
    "logs" {
        $target = $Rest | Where-Object { $_ -notmatch "^-" } | Select-Object -First 1
        $follow = $Rest -contains "-f" -or $Rest -contains "--follow"
        if ($target) {
            $lf = Get-LogFile $target
            if (-not (Test-Path $lf)) { Write-Host "No log: $lf"; exit 1 }
            if ($follow) { Get-Content $lf -Wait -Tail 50 } else { Get-Content $lf -Tail 100 }
        } else {
            $logs = Get-Agents | ForEach-Object { Get-LogFile $_ } | Where-Object { Test-Path $_ }
            $logs | ForEach-Object { Get-Content $_ -Tail 30 }
        }
    }
    "help" {
        Write-Host @"

zybos — ZybOS CLI (Windows)

USAGE
  zybos <command> [options]

COMMANDS
  start   [agent]     Start all agents or a named agent
  stop    [agent]     Stop all agents or a named agent
  restart [agent]     Restart all agents or a named agent
  status              Show running/stopped state
  logs    [agent] -f  Show recent logs; -f to stream

FILES
  Config  : $INSTALL_DIR\config.env
  Logs    : $LogDir\
  PIDs    : $RunDir\
"@
    }
    default { Write-Host "Unknown command: $Command. Run 'zybos help'."; exit 1 }
}
'@ | Set-Content $MainCli

# Update the wrapper to point to the main CLI
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0zybos_main.ps1" %*
"@ | Set-Content $CliBat

# ── 12. Optional: Windows Task Scheduler service ──────────────────────────────
if (-not $NoService) {
    Write-Info "Registering Windows Task Scheduler entry..."
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$CliScript`" start"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 0) -MultipleInstances IgnoreNew
    try {
        Register-ScheduledTask -TaskName "ZybOS" `
          -Action $action -Trigger $trigger -Settings $settings `
          -Description "ZybOS auto-start" `
          -RunLevel Limited -Force | Out-Null
        Write-Ok "Scheduled task registered (starts at login, disabled by default)"
        Write-Host "  To enable: schtasks /Change /TN ZybOS /ENABLE"
    } catch {
        Write-Warn "Could not register scheduled task: $_"
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Start agents  : zybos start"
Write-Host "  Check status  : zybos status"
Write-Host "  View logs     : zybos logs"
Write-Host "  Dashboard     : http://localhost:8000"
Write-Host ""
Write-Host "  Config file   : $ConfigFile"
Write-Host "  Open a new terminal for the 'zybos' command to be available."
Write-Host ""
