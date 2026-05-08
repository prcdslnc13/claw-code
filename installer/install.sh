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
BUILD_PROFILE="release"
DO_WEB_UI=1
DO_WRAPPER=1
DO_SETTINGS=1
DO_BINARY=1
DO_BUILD=1
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
  --release | --debug    Build profile passed to root install.sh (default: release)
  --no-binary            Skip building and installing the claw binary
  --no-wrapper           Skip installing the cl wrapper
  --no-settings          Skip dropping ~/.claw/settings.json
  --no-web-ui            Skip Python venv + web-ui setup
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
        --release)        BUILD_PROFILE="release"; shift ;;
        --debug)          BUILD_PROFILE="debug"; shift ;;
        --no-binary)      DO_BINARY=0; DO_BUILD=0; shift ;;
        --no-wrapper)     DO_WRAPPER=0; shift ;;
        --no-settings)    DO_SETTINGS=0; shift ;;
        --no-web-ui)      DO_WEB_UI=0; shift ;;
        --web-ui-only)    WEB_UI_ONLY=1; DO_BINARY=0; DO_BUILD=0; DO_WRAPPER=0; DO_SETTINGS=0; DO_WEB_UI=1; shift ;;
        -h|--help)        print_usage; exit 0 ;;
        *)                error "unknown argument: $1"; print_usage; exit 2 ;;
    esac
done

# Recompute total step count from enabled phases. Phases:
#   1 detect, 2 source, 3 prereqs, [4 build], [5 binary], [6 settings],
#   [7 wrapper], [8 web-ui], 9 verify
TOTAL_STEPS=3
[ "${DO_BUILD}" = "1" ]    && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_BINARY}" = "1" ]   && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_SETTINGS}" = "1" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_WRAPPER}" = "1" ]  && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[ "${DO_WEB_UI}" = "1" ]   && TOTAL_STEPS=$((TOTAL_STEPS + 1))
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
printf '%s  prefix=%s  profile=%s  lmstudio=%s%s\n' "${C_DIM}" "${INSTALL_PREFIX}" "${BUILD_PROFILE}" "${LMSTUDIO_URL}" "${C_RESET}"
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
info "uname:     ${UNAME_S} ${UNAME_M}"
info "os family: ${OS_FAMILY}${IS_WSL:+ (wsl)}"

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

# --- step 3: prereqs --------------------------------------------------------

step "Checking prerequisites"

MISSING=0

if [ "${DO_BUILD}" = "1" ]; then
    if require_cmd cargo && require_cmd rustc; then
        ok "rust toolchain: $(rustc --version)"
    else
        error "rust toolchain not found in PATH"
        info "install with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
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
        if [ "${OS_FAMILY}" = "macos" ] && require_cmd brew; then
            warn "tmux not found; running: brew install tmux"
            brew install tmux
            ok "tmux: $(tmux -V)"
        else
            error "tmux is required for web-ui"
            info "macOS: brew install tmux"
            info "Debian/Ubuntu: sudo apt install -y tmux"
            MISSING=1
        fi
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
        install -m 0644 "${SCRIPT_DIR}/templates/settings.json" "${SETTINGS_FILE}"
        ok "wrote ${SETTINGS_FILE}"
    fi
fi

# --- step 7: cl wrapper -----------------------------------------------------

if [ "${DO_WRAPPER}" = "1" ]; then
    step "Installing cl wrapper (LMStudio defaults)"
    BIN_DIR="${INSTALL_PREFIX}/bin"
    mkdir -p "${BIN_DIR}"
    WRAPPER="${BIN_DIR}/cl"
    TEMPLATE="${SCRIPT_DIR}/templates/cl"
    # Use a sentinel-aware sed (works with /, : in URL); pipe-delimited so / in URL isn't a problem.
    sed "s|__LMSTUDIO_URL__|${LMSTUDIO_URL}|g" "${TEMPLATE}" > "${WRAPPER}"
    chmod 0755 "${WRAPPER}"
    ok "wrote ${WRAPPER} (OPENAI_BASE_URL=${LMSTUDIO_URL})"
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
