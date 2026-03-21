#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: systemd-manage.sh <install|uninstall> [--scope user|system] [--bin-path /path/to/wsl2-bridge-rs.exe]

Install or uninstall the provided systemd user services either for the current
user (default) or globally in /etc/systemd/user.

The --bin-path option sets the path to the wsl2-bridge-rs.exe binary that will
be written into the installed service files. Defaults to /mnt/c/tools/wsl2-bridge-rs.exe.

Examples:
  systemd-manage.sh install
  systemd-manage.sh install --scope system
  systemd-manage.sh install --bin-path /mnt/d/tools/wsl2-bridge-rs.exe
  systemd-manage.sh uninstall --scope user
EOF
}

err() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
UNIT_SRC="${PROJECT_ROOT}/systemd"

if [[ ! -d ${UNIT_SRC} ]]; then
  err "Expected unit directory ${UNIT_SRC} not found"
fi

mapfile -t UNITS < <(find "${UNIT_SRC}" -maxdepth 1 -type f -name '*.service' -print | sort)
if [[ ${#UNITS[@]} -eq 0 ]]; then
  err "No .service files found in ${UNIT_SRC}"
fi

ACTION=""
SCOPE="user"
BIN_PATH="/mnt/c/tools/wsl2-bridge-rs.exe"

while [[ $# -gt 0 ]]; do
  case $1 in
    install|uninstall)
      ACTION=$1
      shift
      ;;
    --scope)
      [[ $# -ge 2 ]] || err "Missing value for --scope"
      SCOPE=$2
      shift 2
      ;;
    --scope=*)
      SCOPE=${1#*=}
      shift
      ;;
    --bin-path)
      [[ $# -ge 2 ]] || err "Missing value for --bin-path"
      BIN_PATH=$2
      shift 2
      ;;
    --bin-path=*)
      BIN_PATH=${1#*=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

[[ -n ${ACTION} ]] || err "No action provided (install or uninstall)"
case ${SCOPE} in
  user|system)
    ;;
  *)
    err "Scope must be 'user' or 'system'"
    ;;
esac

if ! command -v install >/dev/null 2>&1; then
  err "'install' command not found on PATH"
fi

require_root_for_system_scope() {
  if [[ ${SCOPE} == system && ${EUID} -ne 0 ]]; then
    err "System scope requires root privileges"
  fi
}

run_systemctl() {
  local scope=$1
  shift
  local args=("$@")

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; skipping systemd action: systemctl ${args[*]}"
    return
  fi

  if [[ ${scope} == user ]]; then
    if ! systemctl --user "${args[@]}"; then
      warn "systemctl --user ${args[*]} failed; you may need to run it manually"
    fi
  elif [[ ${scope} == system ]]; then
    if ! systemctl --global "${args[@]}"; then
      warn "systemctl --global ${args[*]} failed; you may need to run it manually"
    fi
  fi
}

install_units() {
  local dest
  if [[ ${SCOPE} == user ]]; then
    local config_home=${XDG_CONFIG_HOME:-${HOME}/.config}
    dest="${config_home}/systemd/user"
  else
    dest="/etc/systemd/user"
  fi

  require_root_for_system_scope
  mkdir -p "${dest}"

  for unit_path in "${UNITS[@]}"; do
    local unit_name
    unit_name=$(basename "${unit_path}")
    sed "s|@WSL2_BRIDGE_BIN@|${BIN_PATH}|g" "${unit_path}" \
      | install -Dm644 /dev/stdin "${dest}/${unit_name}"
  done

  if [[ ${SCOPE} == user ]]; then
    run_systemctl user daemon-reload
    for unit_path in "${UNITS[@]}"; do
      local unit_name
      unit_name=$(basename "${unit_path}")
      run_systemctl user enable --now "${unit_name}"
    done
  else
    warn "Global units installed; each user should run 'systemctl --user daemon-reload'"
    for unit_path in "${UNITS[@]}"; do
      local unit_name
      unit_name=$(basename "${unit_path}")
      run_systemctl system enable "${unit_name}"
    done
  fi
}

uninstall_units() {
  local dest
  if [[ ${SCOPE} == user ]]; then
    local config_home=${XDG_CONFIG_HOME:-${HOME}/.config}
    dest="${config_home}/systemd/user"
  else
    dest="/etc/systemd/user"
  fi

  require_root_for_system_scope

  if [[ -d ${dest} ]]; then
    for unit_path in "${UNITS[@]}"; do
      local unit_name
      unit_name=$(basename "${unit_path}")
      if [[ ${SCOPE} == user ]]; then
        run_systemctl user disable --now "${unit_name}"
      else
        run_systemctl system disable "${unit_name}"
      fi
      if [[ -f ${dest}/${unit_name} ]]; then
        rm -f "${dest}/${unit_name}"
      fi
    done
  fi

  if [[ ${SCOPE} == user ]]; then
    run_systemctl user daemon-reload
  else
    warn "Global unit files removed; active user sessions may need 'systemctl --user daemon-reload'"
  fi
}

case ${ACTION} in
  install)
    install_units
    ;;
  uninstall)
    uninstall_units
    ;;
esac
