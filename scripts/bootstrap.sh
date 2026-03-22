#!/usr/bin/env bash
set -euo pipefail

# Bootstrap wsl2-bridge-rs from inside WSL2.
# Downloads the latest release binary to a Windows-accessible path and
# installs the systemd user services.
#
# Usage:
#   bootstrap.sh [--bin-dir /mnt/c/tools] [--scope user|system]
#
# Options:
#   --bin-dir   Directory (WSL path) where wsl2-bridge-rs.exe is placed.
#               Defaults to /mnt/c/tools.
#   --scope     Systemd install scope: user (default) or system.

REPO="ArturoGuerra/wsl2-bridge-rs"
BIN_NAME="wsl2-bridge-rs.exe"
BIN_DIR="/mnt/c/tools"
SCOPE="user"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main/scripts"

# When run via curl pipe, BASH_SOURCE[0] is unset or just "bash".
# Detect this and fetch all needed files from GitHub into a temp tree.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  MANAGE_SCRIPT="${SCRIPT_DIR}/systemd-manage.sh"
  CLEANUP_TMPDIR=""
else
  WORK_DIR=$(mktemp -d)
  mkdir -p "${WORK_DIR}/scripts" "${WORK_DIR}/systemd"
  MANAGE_SCRIPT="${WORK_DIR}/scripts/systemd-manage.sh"
  curl -fsSL "${RAW_BASE}/systemd-manage.sh" -o "$MANAGE_SCRIPT"
  chmod +x "$MANAGE_SCRIPT"
  RAW_UNITS="https://raw.githubusercontent.com/${REPO}/main/systemd"
  for unit in ssh-agent-relay.service gpg-agent-relay.service gpg-agent-extra-relay.service; do
    curl -fsSL "${RAW_UNITS}/${unit}" -o "${WORK_DIR}/systemd/${unit}"
  done
fi

err()  { echo "Error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --bin-dir)
      [[ $# -ge 2 ]] || err "Missing value for --bin-dir"
      BIN_DIR=$2; shift 2 ;;
    --bin-dir=*)
      BIN_DIR=${1#*=}; shift ;;
    --scope)
      [[ $# -ge 2 ]] || err "Missing value for --scope"
      SCOPE=$2; shift 2 ;;
    --scope=*)
      SCOPE=${1#*=}; shift ;;
    -h|--help)
      sed -n '3,14p' "$0" | sed 's/^# \?//' 2>/dev/null || echo "See script source for usage."
      exit 0 ;;
    *)
      err "Unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null 2>&1 || err "curl is required but not found"

# ---------------------------------------------------------------------------
# 1. Resolve latest release asset URL
# ---------------------------------------------------------------------------
step "Fetching latest release from github.com/$REPO"

release_json=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")
tag=$(echo "$release_json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
download_url=$(echo "$release_json" | grep '"browser_download_url"' | grep "${BIN_NAME}" | head -1 | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

[[ -n $tag ]]          || err "Could not parse tag from GitHub API response"
[[ -n $download_url ]] || err "No asset named '${BIN_NAME}' found in release ${tag}"

echo "    Latest release: $tag"

# ---------------------------------------------------------------------------
# 2. Download binary
# ---------------------------------------------------------------------------
step "Downloading $BIN_NAME to $BIN_DIR"

tmp_bin=$(mktemp /tmp/wsl2-bridge-rs.XXXXXX)
trap 'rm -f "$tmp_bin"; rm -rf "${WORK_DIR:-}"' EXIT
curl -fsSL "$download_url" -o "$tmp_bin"

if ! mkdir -p "$BIN_DIR" 2>/dev/null || ! install -m755 "$tmp_bin" "${BIN_DIR}/${BIN_NAME}" 2>/dev/null; then
  echo "    Requires elevated privileges, prompting for sudo..."
  sudo mkdir -p "$BIN_DIR"
  sudo install -m755 -o "$(id -u)" -g "$(id -g)" "$tmp_bin" "${BIN_DIR}/${BIN_NAME}"
fi

echo "    Saved to ${BIN_DIR}/${BIN_NAME}"

# ---------------------------------------------------------------------------
# 3. Install systemd services
# ---------------------------------------------------------------------------
step "Installing systemd services (scope: $SCOPE)"

bash "$MANAGE_SCRIPT" install \
  --scope "$SCOPE" \
  --bin-path "${BIN_DIR}/${BIN_NAME}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "Bootstrap complete."
echo "  Binary : ${BIN_DIR}/${BIN_NAME}"
echo "  Services installed via systemd ($SCOPE scope)"
echo ""
echo "If SSH_AUTH_SOCK is not set in your shell, add to ~/.bashrc or ~/.zshrc:"
echo '  export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.sock'
