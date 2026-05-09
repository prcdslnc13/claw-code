# Cross-platform installer

Fork-specific install scripts that wrap the upstream-shaped root `install.sh`
with the operational extras this hardened fork actually uses: a stable PATH
location for `claw`, a hardened `~/.claw/settings.json`, an LMStudio (OpenAI
API-compat) wrapper, and the web-ui Python venv.

For the *raw* upstream build (no system install, no settings, no wrapper),
use the root `./install.sh` directly. This directory is the layer that turns
that build into a usable workstation install.

**Designed for clean machines.** By default both scripts auto-install missing
prerequisites (Rust toolchain, tmux, Python ≥ 3.12, Homebrew, distro packages)
so a fresh box only needs `git` to bootstrap. Pass `--no-bootstrap`
(`-NoBootstrap` on Windows) to disable that and only check.

## Quick start

### macOS / Linux / WSL2

```bash
# Clone yourself, or let the installer clone for you.
git clone https://github.com/prcdslnc13/claw-code.git ~/src/claw-code
cd ~/src/claw-code
bash installer/install.sh --release --lmstudio-url http://localhost:1234/v1
```

On a fresh box this single command will (when something is missing):

- macOS — install Homebrew (prompts for sudo), `tmux`, `python@3.12`, and
  `rustup` + the stable Rust toolchain. Xcode Command Line Tools must be
  present; if not, the installer triggers the GUI prompt and asks you to
  re-run after it finishes.
- Linux / WSL2 — `sudo apt|dnf|pacman|zypper install` the right system
  packages (`git`, `tmux`, `python3-venv`, `build-essential`, `libssl-dev`,
  `pkg-config`), then install `rustup` for your user.

Drops:

| Artifact | Path |
|---|---|
| `claw` binary | `$HOME/.local/bin/claw` |
| `cl` LMStudio wrapper | `$HOME/.local/bin/cl` |
| Hardened settings | `$HOME/.claw/settings.json` (only if missing) |
| web-ui venv | `<source>/web-ui/.venv/` |

### Windows 11 (native + WSL2 hybrid for web-ui)

From an elevated **PowerShell 7+** (or 5.1) prompt:

```powershell
git clone https://github.com/prcdslnc13/claw-code.git $env:USERPROFILE\src\claw-code
cd $env:USERPROFILE\src\claw-code
.\installer\install.ps1 -Release -LmStudioUrl http://localhost:1234/v1
```

On a fresh box this will `winget install` Git and `Rustlang.Rustup` if
they're missing. It does **not** auto-install MSVC build tools or a WSL2
distro — both are large and may need a reboot. The installer prints the
exact `winget` / `wsl` commands and exits cleanly so you can run them and
re-launch.

Drops:

| Artifact | Path |
|---|---|
| `claw.exe` | `%LOCALAPPDATA%\Programs\claw\claw.exe` |
| `cl.ps1` LMStudio wrapper | `%LOCALAPPDATA%\Programs\claw\cl.ps1` |
| Hardened settings | `%USERPROFILE%\.claw\settings.json` (only if missing) |
| web-ui venv | inside the chosen WSL2 distro at `<wsl-source>/web-ui/.venv/` |

The PowerShell installer translates the Windows source path to a WSL path via
`wslpath -a` and runs `installer/install.sh --web-ui-only` inside the first
installed distro (or `-WslDistro <name>` to pin one). Native Windows can't
host web-ui because it depends on `tmux`.

## Flags

### `installer/install.sh`

```
--prefix DIR            Install prefix (default: $HOME/.local)
--source-dir DIR        Use this checkout instead of cloning
--lmstudio-url URL      OPENAI_BASE_URL baked into the cl wrapper
                        (default: http://localhost:1234/v1)
--default-model MODEL   Default --model baked into the cl wrapper and
                        ~/.claw/settings.json template
                        (default: openai/qwen/qwen3.5-9b)
--release | --debug     Build profile (default: release)
--no-binary             Skip building and installing the claw binary
--no-wrapper            Skip installing the cl wrapper
--no-settings           Skip dropping ~/.claw/settings.json
--no-web-ui             Skip Python venv + web-ui setup
--no-bootstrap          Don't auto-install missing prerequisites; just check
                        and bail with hints if anything is missing
--web-ui-only           Skip everything except web-ui bootstrap
                        (used by install.ps1 over WSL2)
-h, --help              Show usage
```

### `installer/install.ps1`

```
-Prefix DIR             Install prefix (default: %LOCALAPPDATA%\Programs\claw)
-SourceDir DIR          Native Windows checkout (default: %USERPROFILE%\src\claw-code)
-LmStudioUrl URL        OPENAI_BASE_URL for the cl.ps1 wrapper
-Release | -Debug       Cargo profile (default: release)
-NoBinary               Skip building and installing claw.exe
-NoWrapper              Skip installing cl.ps1
-NoSettings             Skip dropping settings.json
-NoWebUi                Skip WSL2 web-ui bootstrap
-NoBootstrap            Don't auto-install missing prerequisites via winget;
                        just check and bail with hints if anything is missing
-WslDistro NAME         Pin which WSL distro to use (default: first from `wsl -l -q`)
```

## Idempotency

Both scripts are safe to re-run. They will:

- Reuse an existing source checkout (and `git fetch` it).
- Reuse an existing Python venv if it's already there.
- **Never** overwrite `~/.claw/settings.json` if the file exists — the template
  only lands on a fresh box.
- Always overwrite the `claw` binary and the `cl`/`cl.ps1` wrapper (so re-runs
  pick up new builds and updated `--lmstudio-url`).

## Verification

After a run, you should see:

```bash
$ ~/.local/bin/claw --version
claw 0.1.0 (...)

$ cat ~/.claw/settings.json | python3 -m json.tool | head
{
    "permissions": {
        "defaultMode": "default",
        ...
    }
}

$ ~/.local/bin/cl status      # talks to LMStudio
Permission mode  read-only
...
```

If `~/.local/bin` (or `%LOCALAPPDATA%\Programs\claw`) isn't on `PATH`, the
installer prints the line you need to add to your shell's rc file (or notes
that user PATH was updated and you need a fresh shell).

## Prerequisites

By default the installers will install all of these automatically (use
`--no-bootstrap` / `-NoBootstrap` to opt out and only check). The only
hard prerequisites that must already be present:

- **macOS:** Xcode Command Line Tools. The installer triggers the GUI
  prompt and exits cleanly if they're missing — accept the dialog, wait
  for the install, then re-run.
- **Linux / WSL2:** ability to `sudo` the system package manager
  (apt-get, dnf, yum, pacman, or zypper) — the installer asks for your
  password.
- **Windows 11:** `winget` (ships with App Installer, available from the
  Microsoft Store), and PowerShell 5.1 or later.

Everything else (Homebrew, `tmux`, `python@3.12`, the Rust toolchain, the
distro packages `build-essential`/`pkg-config`/`libssl-dev`/`python3-venv`,
and `git` on Windows) gets installed for you on first run.

Two pieces remain manual on Windows because they're large and may require
a reboot:

- **MSVC build tools** — `winget install Microsoft.VisualStudio.2022.BuildTools`
  with the "Desktop development with C++" workload.
- **A WSL2 distro for web-ui** — `wsl --install -d Ubuntu`.

The installer prints the exact commands when these are missing.

## Out of scope

- Auto-start service install (launchd plist, scheduled task, systemd unit).
  The WSL2 systemd recipe still lives in [`docs/local-setup.md`](../docs/local-setup.md);
  cross-platform service install is a separate effort.
- Prebuilt binary download. Today everything compiles from source. The
  `release.yml` workflow only emits Linux/macOS artifacts; once Windows is
  added we can layer a `--prebuilt` mode on these scripts.
- Homebrew tap / winget manifest. Will follow once published artifacts exist.

## Why a separate `installer/` directory?

The root `install.sh` is upstream-shaped — it's something we'd want to keep
mergeable with `ultraworkers/claw-code`. The fork-specific operational
concerns live here, layered on top, the same way `patches/` keeps fork-only
diffs isolated from upstream code paths.
