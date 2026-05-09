#!/usr/bin/env bash
# Fork-specific installer for the hardened claw build.
#
# Layers on top of the upstream-shaped root install.sh. Drops the binary,
# a hardened ~/.claw/settings.json template, an LMStudio wrapper (cl), and
# the web-ui Python venv into stable, user-owned locations.
#
# Supported on macOS, Linux, and Linux-via-WSL2. For native Windows 11 use
# installer/install.ps1.
#
# Usage: bash installer/install.sh [options]   (see --help for flags)

set -euo pipefail

# --- defaults ----------------------------------------------------------------

INSTALL_PREFIX="${HOME}/.local"
SOURCE_DIR=""
LMSTUDIO_URL="http://localhost:1234/v1"
DEFAULT_MODEL="openai/qwen/qwen3.5-9b"
BUILD_PROFILE="release"
DO_WEB_UI=1
DO_WRAPPER=1
DO_SETTINGS=1
DO_BINARY=1
DO_BUILD=1
DO_BOOTSTRAP=1
WEB_UI_ONLY=0
GIT_REMOTE="https://github.com/prcdslnc13/claw-code.git"
DEFAULT_CLONE_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/claw-code"

# --- pretty printing (mirrors root install.sh) -------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"; C_DIM="$(tput dim)"
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
    C_BLUE="$(tput setaf 4)"; C_CYAN="$(tput setaf 6)"
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

CURRENT_STEP=0
TOTAL_STEPS=0  # set after argument parsing once we know what's enabled

step()  { CURRENT_STEP=$((CURRENT_STEP + 1)); printf '\n%s[%d/%d]%s %s%s%s\n' "${C_BLUE}" "${CURRENT_STEP}" "${TOTAL_STEPS}" "${C_RESET}" "${C_BOLD}" "$1" "${C_RESET}"; }
info()  { printf '%s  ->%s %s\n' "${C_CYAN}" "${C_RESET}" "$1"; }
ok()    { printf '%s  ok%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
warn()  { printf '%s  warn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
error() { printf '%s  error%s %s\n' "${C_RED}" "${C_RESET}" "$1" 1>&2; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

print_usage() {
    cat <<EOF
Usage: bash installer/install.sh [options]

Options:
  --prefix DIR           Install prefix (default: \$HOME/.local)
  --source-dir DIR       Use this checkout instead of cloning
  --lmstudio-url URL     OPENAI_BASE_URL baked into the cl wrapper
                         (default: http://localhost:1234/v1)
  --default-model MODEL  Default --model baked into the cl wrapper and
                         ~/.claw/settings.json template
                         (default: openai/qwen/qwen3.5-9b)
  --release | --debug    Build profile passed to root install.sh (default: release)
  --no-binary            Skip building and installing the claw binary
  --no-wrapper           Skip installing the cl wrapper
  --no-settings          Skip dropping ~/.claw/settings.json
  --no-web-ui            Skip Python venv + web-ui setup
  --no-bootstrap         Don't auto-install missing prerequisites; just check
                         and exit if any are missing (rust, tmux, python>=3.12,
                         brew on macOS, system packages on Linux/WSL2)
  --web-ui-only          Skip everything except web-ui bootstrap
                         (used by install.ps1 over WSL2)
  -h, --help             Show this help and exit
EOF
}

# --- arg parsing -------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)         INSTALL_PREFIX="$2"; shift 2 ;;
        --source-dir)     SOURCE_DIR="$2"; shift 2 ;;
        --lmstudio-url)   LMSTUDIO_URL="$2"; shift 2 ;;
        --default-model)  DEFAULT_MODEL="$2"; shift 2 ;;
        --release)        BUILD_PROFILE="release"; shift ;;
        --debug)          BUILD_PROFILE="debug"; shift ;;
        --no-binary)      DO_BINARY=0; DO_BUILD=0; shift ;;
        --no-wrapper)     DO_WRAPPER=0; shift ;;
        --no-settings)    DO_SETTINGS=0; shift ;;
        --no-web-ui)      DO_WEB_UI=0; shift ;;
        --no-bootstrap)   DO_BOOTSTRAP=0; shift ;;
        --web-ui-only)    WEB_UI_ONLY=1; DO_BINARY=0; DO_BUILD=0; DO_WRAPPER=0; DO_SETTINGS=0; DO_WEB_UI=1; shift ;;
        -h|--help)        print_usage; exit 0 ;;
        *)                error "unknown argument: $1"; print_usage; exit 2 ;;
    esac
done

# Recompute total step count from enabled phases. Phases:
#   1 detect, 2 source, [3 bootstrap], 4 prereqs, [5 build], [6 binary],
#   [7 settings], [8 wrapper], [9 web-ui], 10 verify
TOTAL_STEPS=3
[ "${DO_BOOTSTRAP}" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_BUILD}" = "1" ]     && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_BINARY}" = "1" ]    && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_SETTINGS}" = "1" ]  && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_WRAPPER}" = "1" ]   && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_WEB_UI}" = "1" ]    && TOTAL_STEPS=$((TOTAL_STEPS + 1))
TOTAL_STEPS=$((TOTAL_STEPS + 1))  # verify

# --- failure trap with hints -------------------------------------------------

print_troubleshooting() {
    cat <<EOF

${C_BOLD}Troubleshooting${C_RESET}
${C_DIM}---------------${C_RESET}

  ${C_BOLD}Rust toolchain missing${C_RESET}
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "\$HOME/.cargo/env"

  ${C_BOLD}macOS: missing tmux/python${C_RESET}
    brew install tmux python@3.12

  ${C_BOLD}Linux: missing system packages${C_RESET}
    Debian/Ubuntu: sudo apt install -y git tmux python3-venv python3-pip pkg-config libssl-dev build-essential
    Fedora/RHEL:   sudo dnf install -y git tmux python3-virtualenv pkgconf-pkg-config openssl-devel gcc

  ${C_BOLD}<prefix>/bin not on PATH${C_RESET}
    Add to your shell rc:
      export PATH="${INSTALL_PREFIX}/bin:\$PATH"

  ${C_BOLD}Native Windows${C_RESET}
    This script does not support native Windows. Use installer/install.ps1.
EOF
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then error "installer failed (exit ${rc})"; print_troubleshooting; fi' EXIT

# --- banner ------------------------------------------------------------------

printf '%sclaw installer (fork layer)%s\n' "${C_BOLD}" "${C_RESET}"
printf '%s  prefix=%s  profile=%s%s\n' "${C_DIM}" "${INSTALL_PREFIX}" "${BUILD_PROFILE}" "${C_RESET}"
printf '%s  lmstudio=%s  model=%s%s\n' "${C_DIM}" "${LMSTUDIO_URL}" "${DEFAULT_MODEL}" "${C_RESET}"
if [ "${DO_BOOTSTRAP}" = "1" ]; then
    printf '%s  bootstrap=on (will auto-install rust/tmux/python/brew if missing)%s\n' "${C_DIM}" "${C_RESET}"
else
    printf '%s  bootstrap=off (will only check; --no-bootstrap given)%s\n' "${C_DIM}" "${C_RESET}"
fi
if [ "${WEB_UI_ONLY}" = "1" ]; then
    printf '%s  mode=web-ui-only%s\n' "${C_DIM}" "${C_RESET}"
fi

# --- step 1: detect platform -------------------------------------------------

step "Detecting host environment"

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
UNAME_M="$(uname -m 2>/dev/null || echo unknown)"
OS_FAMILY="unknown"
IS_WSL="0"
case "${UNAME_S}" in
    Linux*)
        OS_FAMILY="linux"
        if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then IS_WSL="1"; fi
        ;;
    Darwin*)        OS_FAMILY="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS_FAMILY="windows-shell" ;;
esac
WSL_TAG=""
[ "${IS_WSL}" = "1" ] && WSL_TAG=" (wsl)"
info "uname:     ${UNAME_S} ${UNAME_M}"
info "os family: ${OS_FAMILY}${WSL_TAG}"

case "${OS_FAMILY}" in
    linux|macos) ok "supported platform" ;;
    windows-shell)
        error "Detected a native Windows shell (MSYS/Cygwin/MinGW)."
        error "Use installer\\install.ps1 from PowerShell instead."
        exit 1 ;;
    *)
        error "Unsupported OS: ${UNAME_S}"
        exit 1 ;;
esac

# --- step 2: resolve source dir ---------------------------------------------

step "Resolving source checkout"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_GUESS="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -n "${SOURCE_DIR}" ]; then
    SOURCE_DIR="$(cd "${SOURCE_DIR}" && pwd)"
    info "using --source-dir=${SOURCE_DIR}"
elif [ -f "${REPO_ROOT_GUESS}/rust/Cargo.toml" ] && [ -f "${REPO_ROOT_GUESS}/install.sh" ]; then
    SOURCE_DIR="${REPO_ROOT_GUESS}"
    info "running from a checkout: ${SOURCE_DIR}"
else
    SOURCE_DIR="${DEFAULT_CLONE_DIR}"
    if [ -d "${SOURCE_DIR}/.git" ]; then
        info "reusing existing clone at ${SOURCE_DIR}"
        (cd "${SOURCE_DIR}" && git fetch --quiet origin) || warn "git fetch failed (continuing)"
    else
        info "cloning ${GIT_REMOTE} -> ${SOURCE_DIR}"
        mkdir -p "$(dirname "${SOURCE_DIR}")"
        git clone --quiet "${GIT_REMOTE}" "${SOURCE_DIR}"
    fi
fi

if [ ! -f "${SOURCE_DIR}/rust/Cargo.toml" ] || [ ! -f "${SOURCE_DIR}/install.sh" ]; then
    error "source dir doesn't look like a claw-code checkout: ${SOURCE_DIR}"
    exit 1
fi
ok "source: ${SOURCE_DIR}"

# --- step 3: bootstrap missing prerequisites --------------------------------
#
# When DO_BOOTSTRAP=1 (default) we proactively install anything missing so
# this script can be the single command a user runs on a clean machine. The
# subsequent "Checking prerequisites" step is the verification gate.
#
# What we install (gated by what the run actually needs):
#   - macOS: Xcode CLT (GUI prompt, blocks), Homebrew, rustup, tmux, python@3.12
#   - Linux/WSL2: distro packages via apt/dnf/pacman (sudo), then rustup
#   - Native Windows is not handled here — see installer/install.ps1
#
# Use --no-bootstrap to skip this step (the prereq check below will still run
# and bail with hints if anything is missing).

ensure_xcode_clt_macos() {
    if xcode-select -p >/dev/null 2>&1; then
        info "Xcode CLT: $(xcode-select -p)"
        return 0
    fi
    warn "Xcode Command Line Tools missing — triggering GUI installer"
    xcode-select --install >/dev/null 2>&1 || true
    error "A 'Command Line Tools' install dialog should have appeared. Click"
    error "Install, wait for it to finish, then re-run this script."
    exit 1
}

ensure_brew_macos() {
    if require_cmd brew; then
        info "brew: $(brew --version | head -1)"
        return 0
    fi
    info "Homebrew not found — installing via the official script"
    info "(this will prompt you for your sudo password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    if ! require_cmd brew; then
        error "Homebrew install ran but 'brew' still isn't on PATH"
        exit 1
    fi
    ok "installed brew: $(brew --version | head -1)"
}

ensure_rustup_unix() {
    if require_cmd cargo && require_cmd rustc; then
        info "rust: $(rustc --version)"
        return 0
    fi
    info "Rust toolchain not found — installing via rustup-init"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
    if [ -f "${HOME}/.cargo/env" ]; then
        # shellcheck disable=SC1091
        . "${HOME}/.cargo/env"
    fi
    if ! require_cmd cargo; then
        error "rustup ran but 'cargo' still isn't on PATH (try opening a new shell)"
        exit 1
    fi
    ok "installed rust: $(rustc --version)"
}

ensure_python_312_macos() {
    if require_cmd python3 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
        info "python3: $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
        return 0
    fi
    info "python3 >= 3.12 not found — brew install python@3.12"
    brew install python@3.12
    local brew_py
    brew_py="$(brew --prefix python@3.12 2>/dev/null)/bin"
    if [ -d "${brew_py}" ]; then
        export PATH="${brew_py}:${PATH}"
    fi
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
        error "python@3.12 installed but python3 on PATH is still too old"
        error "PATH=${PATH}"
        exit 1
    fi
    ok "installed python3: $(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
}

ensure_tmux_macos() {
    if require_cmd tmux; then
        info "tmux: $(tmux -V)"
        return 0
    fi
    info "tmux not found — brew install tmux"
    brew install tmux
    if ! require_cmd tmux; then
        error "tmux install failed"
        exit 1
    fi
    ok "installed tmux: $(tmux -V)"
}

linux_pkg_install() {
    # Install one or more system packages via the detected package manager.
    if require_cmd apt-get; then
        info "apt-get install: $*"
        sudo apt-get update -qq
        sudo apt-get install -y "$@"
    elif require_cmd dnf; then
        info "dnf install: $*"
        sudo dnf install -y "$@"
    elif require_cmd yum; then
        info "yum install: $*"
        sudo yum install -y "$@"
    elif require_cmd pacman; then
        info "pacman install: $*"
        sudo pacman -S --noconfirm --needed "$@"
    elif require_cmd zypper; then
        info "zypper install: $*"
        sudo zypper install -y "$@"
    else
        error "No supported package manager (apt/dnf/yum/pacman/zypper) detected."
        error "Install these yourself: $*"
        exit 1
    fi
}

bootstrap_linux() {
    # Map abstract needs → distro-specific package names.
    local need_git=0 need_tmux=0 need_python=0 need_build=0
    require_cmd git || need_git=1
    if [ "${DO_WEB_UI}" = "1" ]; then
        require_cmd tmux || need_tmux=1
        if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' 2>/dev/null; then
            need_python=1
        fi
    fi
    if [ "${DO_BUILD}" = "1" ] && ! require_cmd cargo; then
        # rustup needs a working compiler + linker toolchain to build the std crates.
        need_build=1
    fi

    local pkgs=()
    if require_cmd apt-get; then
        [ "${need_git}" = "1" ]    && pkgs+=(git)
        [ "${need_tmux}" = "1" ]   && pkgs+=(tmux)
        [ "${need_python}" = "1" ] && pkgs+=(python3 python3-venv python3-pip)
        [ "${need_build}" = "1" ]  && pkgs+=(build-essential pkg-config libssl-dev curl ca-certificates)
    elif require_cmd dnf || require_cmd yum; then
        [ "${need_git}" = "1" ]    && pkgs+=(git)
        [ "${need_tmux}" = "1" ]   && pkgs+=(tmux)
        [ "${need_python}" = "1" ] && pkgs+=(python3 python3-virtualenv python3-pip)
        [ "${need_build}" = "1" ]  && pkgs+=(gcc make pkgconf-pkg-config openssl-devel curl ca-certificates)
    elif require_cmd pacman; then
        [ "${need_git}" = "1" ]    && pkgs+=(git)
        [ "${need_tmux}" = "1" ]   && pkgs+=(tmux)
        [ "${need_python}" = "1" ] && pkgs+=(python python-virtualenv python-pip)
        [ "${need_build}" = "1" ]  && pkgs+=(base-devel pkgconf openssl curl ca-certificates)
    elif require_cmd zypper; then
        [ "${need_git}" = "1" ]    && pkgs+=(git)
        [ "${need_tmux}" = "1" ]   && pkgs+=(tmux)
        [ "${need_python}" = "1" ] && pkgs+=(python3 python3-virtualenv python3-pip)
        [ "${need_build}" = "1" ]  && pkgs+=(gcc make pkg-config libopenssl-devel curl ca-certificates)
    fi

    if [ "${#pkgs[@]}" -gt 0 ]; then
        if [ "${EUID:-$(id -u)}" -ne 0 ] && ! require_cmd sudo; then
            error "Root or sudo required to install: ${pkgs[*]}"
            exit 1
        fi
        linux_pkg_install "${pkgs[@]}"
    else
        info "all distro packages already present"
    fi

    if [ "${DO_BUILD}" = "1" ]; then
        ensure_rustup_unix
    fi
}

bootstrap_macos() {
    ensure_xcode_clt_macos
    ensure_brew_macos
    if [ "${DO_WEB_UI}" = "1" ]; then
        ensure_python_312_macos
        ensure_tmux_macos
    fi
    if [ "${DO_BUILD}" = "1" ]; then
        ensure_rustup_unix
    fi
}

if [ "${DO_BOOTSTRAP}" = "1" ]; then
    step "Bootstrapping missing prerequisites"
    case "${OS_FAMILY}" in
        macos) bootstrap_macos ;;
        linux) bootstrap_linux ;;
    esac
    ok "bootstrap complete"
fi

# --- step 4: prereqs --------------------------------------------------------

step "Checking prerequisites"

MISSING=0

if [ "${DO_BUILD}" = "1" ]; then
    if require_cmd cargo && require_cmd rustc; then
        ok "rust toolchain: $(rustc --version)"
    else
        error "rust toolchain not found in PATH"
        info "install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        info "(or rerun this script without --no-bootstrap to install automatically)"
        MISSING=1
    fi
fi

if require_cmd git; then
    ok "git: $(git --version)"
else
    error "git is required"
    MISSING=1
fi

if [ "${DO_WEB_UI}" = "1" ]; then
    if require_cmd python3; then
        PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "?")"
        if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
            ok "python3: ${PY_VER}"
        else
            error "python3 ${PY_VER} found, but web-ui needs >= 3.12"
            MISSING=1
        fi
    else
        error "python3 is required for web-ui (>=3.12)"
        MISSING=1
    fi

    if require_cmd tmux; then
        ok "tmux: $(tmux -V)"
    else
        error "tmux is required for web-ui"
        info "macOS: brew install tmux"
        info "Debian/Ubuntu: sudo apt install -y tmux"
        info "(or rerun this script without --no-bootstrap to install automatically)"
        MISSING=1
    fi
fi

if [ "${MISSING}" -ne 0 ]; then
    error "Missing prerequisites — see hints above and re-run."
    exit 1
fi

# --- step 4: delegated build ------------------------------------------------

if [ "${DO_BUILD}" = "1" ]; then
    step "Building claw (delegating to root install.sh)"
    info "running: bash ${SOURCE_DIR}/install.sh --${BUILD_PROFILE}"
    bash "${SOURCE_DIR}/install.sh" "--${BUILD_PROFILE}" --no-verify
    BUILT_BIN="${SOURCE_DIR}/rust/target/${BUILD_PROFILE}/claw"
    if [ ! -x "${BUILT_BIN}" ]; then
        error "expected ${BUILT_BIN} after build"
        exit 1
    fi
    ok "built ${BUILT_BIN}"
fi

# --- step 5: install binary -------------------------------------------------

if [ "${DO_BINARY}" = "1" ]; then
    step "Installing claw binary"
    BIN_DIR="${INSTALL_PREFIX}/bin"
    mkdir -p "${BIN_DIR}"
    BUILT_BIN="${SOURCE_DIR}/rust/target/${BUILD_PROFILE}/claw"
    if [ ! -x "${BUILT_BIN}" ]; then
        error "no binary at ${BUILT_BIN} (did you skip --no-binary on a fresh box?)"
        exit 1
    fi
    install -m 0755 "${BUILT_BIN}" "${BIN_DIR}/claw"
    ok "installed -> ${BIN_DIR}/claw"

    case ":${PATH}:" in
        *":${BIN_DIR}:"*) ok "${BIN_DIR} already on PATH" ;;
        *) warn "${BIN_DIR} is not on PATH — add: export PATH=\"${BIN_DIR}:\$PATH\"" ;;
    esac
fi

# --- step 6: hardened settings ----------------------------------------------

if [ "${DO_SETTINGS}" = "1" ]; then
    step "Installing hardened ~/.claw/settings.json"
    SETTINGS_DIR="${HOME}/.claw"
    SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
    mkdir -p "${SETTINGS_DIR}"
    if [ -f "${SETTINGS_FILE}" ]; then
        info "${SETTINGS_FILE} already exists — leaving untouched"
    else
        sed "s|__DEFAULT_MODEL__|${DEFAULT_MODEL}|g" \
            "${SCRIPT_DIR}/templates/settings.json" > "${SETTINGS_FILE}"
        chmod 0644 "${SETTINGS_FILE}"
        ok "wrote ${SETTINGS_FILE} (model=${DEFAULT_MODEL})"
    fi
fi

# --- step 7: cl wrapper -----------------------------------------------------

if [ "${DO_WRAPPER}" = "1" ]; then
    step "Installing cl wrapper (LMStudio defaults)"
    BIN_DIR="${INSTALL_PREFIX}/bin"
    mkdir -p "${BIN_DIR}"
    WRAPPER="${BIN_DIR}/cl"
    TEMPLATE="${SCRIPT_DIR}/templates/cl"
    # Pipe-delimited sed so the / in URLs and model names is safe.
    sed -e "s|__LMSTUDIO_URL__|${LMSTUDIO_URL}|g" \
        -e "s|__DEFAULT_MODEL__|${DEFAULT_MODEL}|g" \
        "${TEMPLATE}" > "${WRAPPER}"
    chmod 0755 "${WRAPPER}"
    ok "wrote ${WRAPPER} (OPENAI_BASE_URL=${LMSTUDIO_URL}, --model=${DEFAULT_MODEL})"
fi

# --- step 8: web-ui bootstrap -----------------------------------------------

if [ "${DO_WEB_UI}" = "1" ]; then
    step "Bootstrapping web-ui (${SOURCE_DIR}/web-ui/.venv)"
    WEB_DIR="${SOURCE_DIR}/web-ui"
    if [ ! -f "${WEB_DIR}/server/pyproject.toml" ]; then
        error "no pyproject at ${WEB_DIR}/server — checkout looks incomplete"
        exit 1
    fi
    VENV="${WEB_DIR}/.venv"
    if [ ! -d "${VENV}" ]; then
        info "creating venv at ${VENV}"
        python3 -m venv "${VENV}"
    else
        info "reusing venv at ${VENV}"
    fi
    "${VENV}/bin/pip" install --quiet --upgrade pip
    "${VENV}/bin/pip" install --quiet -e "${WEB_DIR}/server[dev]"
    ok "web-ui ready (claw-web entry: ${VENV}/bin/claw-web)"
fi

# --- step 9: verify + next steps --------------------------------------------

step "Next steps"

if [ "${DO_BINARY}" = "1" ]; then
    BIN="${INSTALL_PREFIX}/bin/claw"
    if VERSION_OUT="$("${BIN}" --version 2>&1)"; then
        ok "${BIN} -> ${VERSION_OUT}"
    else
        warn "${BIN} --version failed; check the binary"
    fi
fi

cat <<EOF

${C_GREEN}Install complete.${C_RESET}

  Source:  ${SOURCE_DIR}
EOF
if [ "${DO_BINARY}" = "1" ]; then
    cat <<EOF
  Binary:  ${INSTALL_PREFIX}/bin/claw
EOF
fi
if [ "${DO_WRAPPER}" = "1" ]; then
    cat <<EOF
  Wrapper: ${INSTALL_PREFIX}/bin/cl  (OPENAI_BASE_URL=${LMSTUDIO_URL})
EOF
fi
if [ "${DO_SETTINGS}" = "1" ]; then
    cat <<EOF
  Config:  ${HOME}/.claw/settings.json
EOF
fi
if [ "${DO_WEB_UI}" = "1" ]; then
    cat <<EOF
  Web-UI:  ${SOURCE_DIR}/web-ui/.venv/bin/claw-web
EOF
fi

printf '\nTry it out:\n'
if [ "${DO_BINARY}" = "1" ]; then
    cat <<EOF
  ${C_DIM}# REPL against the Anthropic API (or whatever your settings.json points to)${C_RESET}
  ${INSTALL_PREFIX}/bin/claw

EOF
fi
if [ "${DO_WRAPPER}" = "1" ]; then
    cat <<EOF
  ${C_DIM}# REPL against LMStudio${C_RESET}
  ${INSTALL_PREFIX}/bin/cl

EOF
fi
if [ "${DO_WEB_UI}" = "1" ]; then
    cat <<EOF
  ${C_DIM}# Web UI (in another terminal)${C_RESET}
  cd ${SOURCE_DIR}/web-ui && CLAW_WEB_MODE=subprocess .venv/bin/claw-web

EOF
fi

trap - EXIT
