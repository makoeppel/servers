#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y cifs-utils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y cifs-utils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y cifs-utils
  elif command -v zypper >/dev/null 2>&1; then
    zypper -n install cifs-utils
  else
    echo "Unsupported package manager. Install 'cifs-utils' manually." >&2
    exit 1
  fi
}

sanitize_name() {
  # allow letters, numbers, dash, underscore only
  local n="$1"
  n="${n// /-}"
  if [[ ! "$n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid name '$1'. Use only letters, numbers, dash, underscore." >&2
    return 1
  fi
  echo "$n"
}

unit_name_from_mountpoint() {
  # /mnt/import -> mnt-import.mount
  local mp="$1"
  mp="${mp#/}"
  mp="${mp//\//-}"
  echo "${mp}.mount"
}

prompt_one_mount() {
  echo
  echo "=== Add a CIFS mount ==="

  read -rp "Mount name (e.g. import, media, photos): " RAW_NAME
  [[ -z "${RAW_NAME}" ]] && { echo "Name is required."; return 1; }
  NAME="$(sanitize_name "${RAW_NAME}")"

  read -rp "Remote share (UNC, e.g. //server/share): " CIFS_REMOTE
  [[ -z "${CIFS_REMOTE}" ]] && { echo "Remote share is required."; return 1; }

  read -rp "Mount point (e.g. /mnt/${NAME}): " MOUNTPOINT
  [[ -z "${MOUNTPOINT}" ]] && { echo "Mount point is required."; return 1; }

  read -rp "Username: " USERNAME
  [[ -z "${USERNAME}" ]] && { echo "Username is required."; return 1; }

  read -rsp "Password: " PASSWORD
  echo
  [[ -z "${PASSWORD}" ]] && { echo "Password is required."; return 1; }

  read -rp "Domain / Workgroup (leave blank if none): " DOMAIN
  DOMAIN="${DOMAIN:-}"

  read -rp "SMB version [3.0]: " CIFS_VERS
  CIFS_VERS="${CIFS_VERS:-3.0}"

  read -rp "Extra mount options (comma-separated, optional): " EXTRA_OPTS
  EXTRA_OPTS="${EXTRA_OPTS:-}"
}

write_credentials_for_name() {
  local name="$1"
  local cred_file="/etc/cifs-credentials-${name}"

  umask 077
  {
    echo "username=${USERNAME}"
    echo "password=${PASSWORD}"
    if [[ -n "${DOMAIN}" ]]; then
      echo "domain=${DOMAIN}"
    fi
  } > "${cred_file}"
  chmod 600 "${cred_file}"

  echo "${cred_file}"
}

write_mount_unit() {
  local name="$1"
  local cred_file="$2"

  mkdir -p "${MOUNTPOINT}"

  local mount_unit
  mount_unit="$(unit_name_from_mountpoint "${MOUNTPOINT}")"
  local mount_unit_path="/etc/systemd/system/${mount_unit}"

  # Build Options=
  local opts="credentials=${cred_file}"
  #,_netdev,nofail,iocharset=utf8,vers=${CIFS_VERS}"
  if [[ -n "${EXTRA_OPTS}" ]]; then
    opts="${opts},${EXTRA_OPTS}"
  fi

  cat > "${mount_unit_path}" <<EOF
[Unit]
Description=Mount CIFS share '${name}' (${CIFS_REMOTE} -> ${MOUNTPOINT})
Wants=network-online.target
After=network-online.target

[Mount]
What=${CIFS_REMOTE}
Where=${MOUNTPOINT}
Type=cifs
Options=${opts}

[Install]
WantedBy=multi-user.target
EOF

  echo "${mount_unit}"
}

write_wrapper_service() {
  # Friendly service name: cifs-<name>.service
  local name="$1"
  local mount_unit="$2"

  local svc="cifs-${name}.service"
  local svc_path="/etc/systemd/system/${svc}"

  cat > "${svc_path}" <<EOF
[Unit]
Description=Friendly wrapper for CIFS mount '${name}'
Wants=${mount_unit}
After=network-online.target
Requires=${mount_unit}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemctl start ${mount_unit}
ExecStop=/usr/bin/systemctl stop ${mount_unit}

[Install]
WantedBy=multi-user.target
EOF

  echo "${svc}"
}

enable_and_start() {
  local mount_unit="$1"
  local wrapper_svc="$2"

  systemctl daemon-reload

  # Enable the mount unit itself (mounts on boot)
  systemctl enable --now "${mount_unit}"

  # Also enable wrapper for convenience (optional, but nice)
  systemctl enable --now "${wrapper_svc}" >/dev/null 2>&1 || true
}

verify() {
  local name="$1"
  local mount_unit="$2"
  local wrapper_svc="$3"

  echo
  echo "=== Verification for '${name}' ==="
  findmnt "${MOUNTPOINT}" || true
  echo
  echo "systemd mount unit: ${mount_unit}"
  systemctl --no-pager --full status "${mount_unit}" || true
  echo
  echo "friendly service: ${wrapper_svc}"
  systemctl --no-pager --full status "${wrapper_svc}" || true
}

main() {
  require_root
  install_packages

  while true; do
    prompt_one_mount

    local cred_file mount_unit wrapper_svc
    cred_file="$(write_credentials_for_name "${NAME}")"
    mount_unit="$(write_mount_unit "${NAME}" "${cred_file}")"
    wrapper_svc="$(write_wrapper_service "${NAME}" "${mount_unit}")"

    enable_and_start "${mount_unit}" "${wrapper_svc}"
    verify "${NAME}" "${mount_unit}" "${wrapper_svc}"

    echo
    read -rp "Add another mount? [y/N]: " AGAIN
    AGAIN="${AGAIN:-N}"
    if [[ ! "${AGAIN}" =~ ^[Yy]$ ]]; then
      break
    fi
  done

  echo
  echo "Done."
  echo "You can manage mounts by mountpoint-unit (required by systemd), e.g.:"
  echo "  systemctl status mnt-foo.mount"
  echo "Or by friendly name service:"
  echo "  systemctl status cifs-<name>.service"
}

main "$@"

