#requires -Version 5.1
<#
.SYNOPSIS
    Fork-specific installer for the hardened claw build on Windows 11.

.DESCRIPTION
    Builds claw.exe natively (MSVC), installs it under
    $env:LOCALAPPDATA\Programs\claw, drops a hardened
    %USERPROFILE%\.claw\settings.json, installs a cl.ps1 wrapper that
    sets OPENAI_BASE_URL/OPENAI_API_KEY for an LMStudio backend, and —
    unless -NoWebUi — bootstraps web-ui inside an existing WSL2 distro.

    For native macOS / Linux / WSL2 use installer/install.sh instead.

.EXAMPLE
    .\installer\install.ps1 -Release -SourceDir D:\src\claw-code -LmStudioUrl http://localhost:1234/v1
#>

[CmdletBinding()]
param(
    [string]$Prefix       = (Join-Path $env:LOCALAPPDATA 'Programs\claw'),
    [string]$SourceDir    = (Join-Path $env:USERPROFILE 'src\claw-code'),
    [string]$LmStudioUrl  = 'http://localhost:1234/v1',
    [string]$DefaultModel = 'openai/qwen/qwen3.5-9b',
    [string]$WslDistro    = '',
    [switch]$Release,
    [switch]$Debug,
    [switch]$NoBinary,
    [switch]$NoWrapper,
    [switch]$NoSettings,
    [switch]$NoWebUi,
    [switch]$NoBootstrap
)

$ErrorActionPreference = 'Stop'

# --- pretty printing --------------------------------------------------------

$script:CurrentStep = 0
$script:TotalSteps  = 0

function Write-Step([string]$msg) {
    $script:CurrentStep++
    Write-Host ""
    Write-Host ("[{0}/{1}] " -f $script:CurrentStep, $script:TotalSteps) -ForegroundColor Blue -NoNewline
    Write-Host $msg
}
function Write-Info([string]$m) { Write-Host "  -> $m" -ForegroundColor Cyan }
function Write-OK  ([string]$m) { Write-Host "  ok $m"   -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  warn $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "  error $m" -ForegroundColor Red }

function Test-Cmd([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# --- profile resolution -----------------------------------------------------

$BuildProfile = 'release'
if ($Debug -and $Release) { throw "Cannot pass both -Debug and -Release." }
if ($Debug)   { $BuildProfile = 'debug' }
if ($Release) { $BuildProfile = 'release' }

# --- step count -------------------------------------------------------------
# 1 detect, [2 bootstrap], 3 prereqs, 4 source, [5 build], [6 binary],
# [7 settings], [8 wrapper], [9 web-ui], 10 verify

$script:TotalSteps = 3
if (-not $NoBootstrap){ $script:TotalSteps += 1 }
if (-not $NoBinary)   { $script:TotalSteps += 2 }   # build + install binary
if (-not $NoSettings) { $script:TotalSteps += 1 }
if (-not $NoWrapper)  { $script:TotalSteps += 1 }
if (-not $NoWebUi)    { $script:TotalSteps += 1 }
$script:TotalSteps += 1                              # verify

# --- banner -----------------------------------------------------------------

Write-Host "claw installer (fork layer, Windows)" -ForegroundColor White
Write-Host ("  prefix={0}  profile={1}" -f $Prefix, $BuildProfile) -ForegroundColor DarkGray
Write-Host ("  lmstudio={0}  model={1}" -f $LmStudioUrl, $DefaultModel) -ForegroundColor DarkGray
if ($NoBootstrap) {
    Write-Host "  bootstrap=off (will only check; -NoBootstrap given)" -ForegroundColor DarkGray
} else {
    Write-Host "  bootstrap=on (winget-installs missing git/rust if found; warns for VS BuildTools/WSL2)" -ForegroundColor DarkGray
}

# --- step 1: detect environment --------------------------------------------

Write-Step "Detecting host environment"

$os  = Get-CimInstance Win32_OperatingSystem
$arch = $env:PROCESSOR_ARCHITECTURE
Write-Info ("OS: {0} (build {1}), arch: {2}" -f $os.Caption, $os.BuildNumber, $arch)
Write-Info ("PowerShell: {0}" -f $PSVersionTable.PSVersion)

if (-not $os.Caption.Contains('Windows 11') -and -not $os.Caption.Contains('Windows 10')) {
    Write-Warn "This installer targets Windows 10/11; you may run into issues."
}
Write-OK "platform detected"

# --- step 1.5: bootstrap missing prerequisites -----------------------------
#
# When -NoBootstrap is NOT passed (the default), proactively install whatever
# we can install non-interactively via winget so the script can be the single
# command a user runs on a clean Windows 11 box.
#
# What we attempt:
#   - git           winget install --id Git.Git
#   - rust          winget install --id Rustlang.Rustup (only if -NoBinary not set)
# What we cannot fully automate (still surfaced as instructions):
#   - MSVC build tools (multi-GB, may need a reboot, large UI flow)
#   - WSL2 distro install (`wsl --install -d Ubuntu` requires a reboot to finish)

function Invoke-Winget {
    param([Parameter(Mandatory)][string]$Id, [string]$Source = 'winget')
    & winget install --exact --id $Id --source $Source `
        --accept-source-agreements --accept-package-agreements `
        --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget install $Id failed (exit $LASTEXITCODE)"
    }
}

function Reload-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user) -join ';'
}

if (-not $NoBootstrap) {
    Write-Step "Bootstrapping missing prerequisites"

    if (-not (Test-Cmd 'winget')) {
        Write-Warn "winget not on PATH — cannot auto-install dependencies."
        Write-Info "Install winget via the Microsoft Store ('App Installer'), then re-run."
        Write-Info "Or pass -NoBootstrap and install git/rust/MSVC manually."
    } else {
        Write-Info ("winget: {0}" -f ((winget --version) 2>$null))

        if (-not (Test-Cmd 'git')) {
            Write-Info "git missing — winget install Git.Git"
            try { Invoke-Winget -Id 'Git.Git' } catch { Write-Err $_.Exception.Message; exit 1 }
            Reload-PathFromRegistry
        } else {
            Write-Info ("git: {0}" -f ((git --version) 2>$null))
        }

        if (-not $NoBinary) {
            if (-not ((Test-Cmd 'cargo') -and (Test-Cmd 'rustc'))) {
                Write-Info "rust missing — winget install Rustlang.Rustup"
                try { Invoke-Winget -Id 'Rustlang.Rustup' } catch { Write-Err $_.Exception.Message; exit 1 }
                Reload-PathFromRegistry
                # rustup-init drops cargo into ~/.cargo/bin; ensure that's on $env:Path for this session
                $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
                if ((Test-Path $cargoBin) -and ($env:Path -notlike "*$cargoBin*")) {
                    $env:Path = "$cargoBin;$env:Path"
                }
            } else {
                Write-Info ("rust: {0}" -f ((rustc --version) 2>$null))
            }

            if (-not (Test-Cmd 'link.exe')) {
                Write-Warn "MSVC linker not on PATH. Cargo will fail without 'Desktop development with C++'"
                Write-Warn "build tools. This installer does NOT auto-install them — they're large"
                Write-Warn "and may require a reboot. Install with:"
                Write-Info  "  winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget"
                Write-Info  "    --override `"--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
                Write-Info  "Then close and re-open PowerShell, and re-run this script."
            }
        }

        if (-not $NoWebUi -and -not (Test-Cmd 'wsl')) {
            Write-Warn "wsl not found. Web-UI needs WSL2. Install with:"
            Write-Info  "  wsl --install -d Ubuntu"
            Write-Info  "Then reboot and re-run this script. (Or pass -NoWebUi to skip web-ui.)"
        }
    }

    Write-OK "bootstrap complete"
}

# --- step 2: prereqs --------------------------------------------------------

Write-Step "Checking prerequisites"

$missing = $false

if (Test-Cmd 'git') {
    Write-OK ("git: {0}" -f ((git --version) 2>$null))
} else {
    Write-Err "git not found"
    Write-Info "install with: winget install --id Git.Git -e --source winget"
    $missing = $true
}

if (-not $NoBinary) {
    if ((Test-Cmd 'cargo') -and (Test-Cmd 'rustc')) {
        Write-OK ("rust: {0}" -f ((rustc --version) 2>$null))
    } else {
        Write-Err "rust toolchain not found"
        Write-Info "install with: winget install --id Rustlang.Rustup -e --source winget"
        $missing = $true
    }

    if (Test-Cmd 'link.exe') {
        Write-OK "MSVC linker on PATH"
    } else {
        Write-Warn "link.exe not on PATH — cargo build will fail without MSVC build tools"
        Write-Info "install: winget install --id Microsoft.VisualStudio.2022.BuildTools -e --source winget"
        Write-Info "then in the VS installer, select 'Desktop development with C++'"
        Write-Info "or run cargo from a 'Developer PowerShell for VS' shell"
    }
}

if (-not $NoWebUi) {
    if (Test-Cmd 'wsl') {
        $distros = @()
        try {
            # `wsl -l -q` emits UTF-16. Read raw bytes and decode.
            $raw = wsl -l -q 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $distros = $raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }
        } catch {
            $distros = @()
        }
        if ($distros.Count -eq 0) {
            Write-Err "WSL2 has no installed distros — web-ui needs WSL2 (tmux + Python)."
            Write-Info "install Ubuntu via: wsl --install -d Ubuntu"
            Write-Info "or rerun with -NoWebUi to skip web-ui"
            $missing = $true
        } else {
            if (-not $WslDistro) { $WslDistro = $distros[0] }
            if ($distros -notcontains $WslDistro) {
                Write-Err ("requested WSL distro '{0}' not found. Available: {1}" -f $WslDistro, ($distros -join ', '))
                $missing = $true
            } else {
                Write-OK ("wsl distros: {0}  (selected: {1})" -f ($distros -join ', '), $WslDistro)
            }
        }
    } else {
        Write-Err "wsl not found — web-ui needs WSL2"
        Write-Info "install: wsl --install"
        Write-Info "or rerun with -NoWebUi to skip web-ui"
        $missing = $true
    }
}

if ($missing) {
    Write-Err "Missing prerequisites — see hints above."
    exit 1
}

# --- step 3: resolve source ------------------------------------------------

Write-Step "Resolving source checkout"

if (Test-Path (Join-Path $SourceDir 'rust\Cargo.toml')) {
    Write-Info ("reusing checkout: {0}" -f $SourceDir)
    try { Push-Location $SourceDir; git fetch --quiet origin } catch { Write-Warn "git fetch failed (continuing)" } finally { Pop-Location }
} else {
    $parent = Split-Path -Parent $SourceDir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Info ("cloning -> {0}" -f $SourceDir)
    git clone --quiet 'https://github.com/prcdslnc13/claw-code.git' $SourceDir
}

if (-not (Test-Path (Join-Path $SourceDir 'rust\Cargo.toml'))) {
    Write-Err ("source dir doesn't look like a claw-code checkout: {0}" -f $SourceDir)
    exit 1
}
Write-OK ("source: {0}" -f $SourceDir)

# --- step 4: build ---------------------------------------------------------

if (-not $NoBinary) {
    Write-Step ("Building claw.exe ({0})" -f $BuildProfile)
    $cargoArgs = @('build', '-p', 'rusty-claude-cli')
    if ($BuildProfile -eq 'release') { $cargoArgs += '--release' }
    Write-Info ("cargo {0}" -f ($cargoArgs -join ' '))
    Push-Location (Join-Path $SourceDir 'rust')
    try {
        & cargo @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    $builtBin = Join-Path $SourceDir ("rust\target\{0}\claw.exe" -f $BuildProfile)
    if (-not (Test-Path $builtBin)) {
        Write-Err ("expected {0} after build" -f $builtBin)
        exit 1
    }
    Write-OK ("built {0}" -f $builtBin)
}

# --- step 5: install binary ------------------------------------------------

if (-not $NoBinary) {
    Write-Step "Installing claw.exe"
    if (-not (Test-Path $Prefix)) { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null }
    $builtBin = Join-Path $SourceDir ("rust\target\{0}\claw.exe" -f $BuildProfile)
    $destBin  = Join-Path $Prefix 'claw.exe'
    Copy-Item -Force $builtBin $destBin
    Write-OK ("installed -> {0}" -f $destBin)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = ($userPath -split ';') | Where-Object { $_ }
    if ($pathEntries -contains $Prefix) {
        Write-OK ("{0} already on user PATH" -f $Prefix)
    } else {
        $newUserPath = if ($userPath) { "$userPath;$Prefix" } else { $Prefix }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        Write-OK ("added {0} to user PATH (open a new shell to pick it up)" -f $Prefix)
    }
}

# --- step 6: hardened settings --------------------------------------------

if (-not $NoSettings) {
    Write-Step "Installing hardened %USERPROFILE%\.claw\settings.json"
    $settingsDir  = Join-Path $env:USERPROFILE '.claw'
    $settingsFile = Join-Path $settingsDir 'settings.json'
    $template     = Join-Path $PSScriptRoot 'templates\settings.json'
    if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
    if (Test-Path $settingsFile) {
        Write-Info ("{0} already exists — leaving untouched" -f $settingsFile)
    } else {
        (Get-Content -Raw $template).Replace('__DEFAULT_MODEL__', $DefaultModel) |
            Set-Content -Path $settingsFile
        Write-OK ("wrote {0} (model={1})" -f $settingsFile, $DefaultModel)
    }
}

# --- step 7: cl.ps1 wrapper -----------------------------------------------

if (-not $NoWrapper) {
    Write-Step "Installing cl.ps1 wrapper"
    if (-not (Test-Path $Prefix)) { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null }
    $template = Join-Path $PSScriptRoot 'templates\cl.ps1'
    $wrapper  = Join-Path $Prefix 'cl.ps1'
    (Get-Content -Raw $template).
        Replace('__LMSTUDIO_URL__', $LmStudioUrl).
        Replace('__DEFAULT_MODEL__', $DefaultModel) |
        Set-Content -Path $wrapper
    Write-OK ("wrote {0} (OPENAI_BASE_URL={1}, --model={2})" -f $wrapper, $LmStudioUrl, $DefaultModel)
}

# --- step 8: web-ui via WSL2 ----------------------------------------------

if (-not $NoWebUi) {
    Write-Step ("Bootstrapping web-ui inside WSL2 distro: {0}" -f $WslDistro)

    # Translate the Windows source dir to a WSL path using the chosen distro's wslpath.
    $wslSource = (& wsl -d $WslDistro -- wslpath -a "$SourceDir") 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $wslSource) {
        Write-Err ("could not translate {0} to a WSL path" -f $SourceDir)
        exit 1
    }
    $wslSource = $wslSource.Trim()
    Write-Info ("WSL path: {0}" -f $wslSource)

    Write-Info "running install.sh --web-ui-only inside WSL2"
    $cmd = "bash '$wslSource/installer/install.sh' --web-ui-only --source-dir '$wslSource'"
    & wsl -d $WslDistro -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Err ("WSL2 web-ui bootstrap failed (exit {0})" -f $LASTEXITCODE)
        exit 1
    }
    Write-OK "web-ui bootstrapped inside WSL2"
}

# --- step 9: verify + next steps ------------------------------------------

Write-Step "Next steps"

if (-not $NoBinary) {
    $destBin = Join-Path $Prefix 'claw.exe'
    try {
        $ver = & $destBin --version 2>&1
        Write-OK ("{0} -> {1}" -f $destBin, $ver)
    } catch {
        Write-Warn ("{0} --version failed; check the binary" -f $destBin)
    }
}

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host ("  Source:  {0}" -f $SourceDir)
if (-not $NoBinary)   { Write-Host ("  Binary:  {0}\claw.exe" -f $Prefix) }
if (-not $NoWrapper)  { Write-Host ("  Wrapper: {0}\cl.ps1  (OPENAI_BASE_URL={1}, --model={2})" -f $Prefix, $LmStudioUrl, $DefaultModel) }
if (-not $NoSettings) { Write-Host ("  Config:  {0}\.claw\settings.json" -f $env:USERPROFILE) }
if (-not $NoWebUi)    { Write-Host ("  Web-UI:  inside WSL2 distro '{0}' at <wsl-source>/web-ui/.venv/bin/claw-web" -f $WslDistro) }

Write-Host ""
Write-Host "Try it out:" -ForegroundColor White
Write-Host "  # REPL against Anthropic / configured backend"
Write-Host ("  & '{0}\claw.exe'" -f $Prefix)
Write-Host ""
Write-Host "  # REPL against LMStudio"
Write-Host ("  & '{0}\cl.ps1'" -f $Prefix)
if (-not $NoWebUi) {
    Write-Host ""
    Write-Host "  # Web UI (inside WSL2)"
    Write-Host ("  wsl -d {0} -- bash -c 'cd <wsl-source>/web-ui && CLAW_WEB_MODE=subprocess .venv/bin/claw-web'" -f $WslDistro)
}
Write-Host ""
