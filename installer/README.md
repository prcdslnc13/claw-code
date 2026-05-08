# Cross-platform installer

Fork-specific install scripts that wrap the upstream-shaped root `install.sh`
with the operational extras this hardened fork actually uses: a stable PATH
location for `claw`, a hardened `~/.claw/settings.json`, an LMStudio (OpenAI
API-compat) wrapper, and the web-ui Python venv.

For the *raw* upstream build (no system install, no settings, no wrapper),
use the root `./install.sh` directly. This directory is the layer that turns
that build into a usable workstation install.

## Quick start

### macOS / Linux / WSL2

```bash
# Clone yourself, or let the installer clone for you.
git clone https://github.com/prcdslnc13/claw-code.git ~/src/claw-code
cd ~/src/claw-code
bash installer/install.sh --release --lmstudio-url http://localhost:1234/v1
```

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
--release | --debug     Build profile (default: release)
--no-binary             Skip building and installing the claw binary
--no-wrapper            Skip installing the cl wrapper
--no-settings           Skip dropping ~/.claw/settings.json
--no-web-ui             Skip Python venv + web-ui setup
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

The installers will tell you about anything missing and link to the install
command. In short:

- **macOS:** Xcode CLT (`xcode-select --install`), Homebrew (for `tmux`), Rust
  via `rustup`, Python 3.12+.
- **Linux / WSL2:** `git`, `tmux`, `python3-venv`, `pkg-config`, `libssl-dev`,
  `build-essential`, Rust via `rustup`.
- **Windows 11:** `git` (via winget), Rust via `rustup` (winget), MSVC build
  tools (Visual Studio 2022 BuildTools with the "Desktop development with
  C++" workload), and a WSL2 distro if you want web-ui.

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
