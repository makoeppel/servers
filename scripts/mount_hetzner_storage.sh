#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Please run this script as root (use sudo)." >&2
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

prompt_values() {
  echo "=== CIFS Mount Configuration ==="

  read -rp "Remote share (UNC, e.g. //server/share): " CIFS_REMOTE
  [[ -z "$CIFS_REMOTE" ]] && { echo "Remote share is required."; exit 1; }

  read -rp "Mount point (e.g. /mnt/import): " MOUNTPOINT
  [[ -z "$MOUNTPOINT" ]] && { echo "Mount point is required."; exit 1; }

  read -rp "Username: " USERNAME
  [[ -z "$USERNAME" ]] && { echo "Username is required."; exit 1; }

  read -rsp "Password: " PASSWORD
  echo
  [[ -z "$PASSWORD" ]] && { echo "Password is required."; exit 1; }

  read -rp "Domain / Workgroup: " DOMAIN
  [[ -z "$DOMAIN" ]] && { echo "Domain is required."; exit 1; }

  read -rp "SMB version [3.0]: " CIFS_VERS
  CIFS_VERS="${CIFS_VERS:-3.0}"
}

write_credentials() {
  local cred_file="/etc/cifs-credentials-import"
  umask 077
  cat > "$cred_file" <<EOF
username=$USERNAME
password=$PASSWORD
domain=$DOMAIN
EOF
  chmod 600 "$cred_file"
}

make_mountpoint() {
  mkdir -p "$MOUNTPOINT"
}

systemd_unit_name() {
  local mp="${MOUNTPOINT#/}"
  mp="${mp//\//-}"
  echo "${mp}.mount"
}

write_systemd_unit() {
  local unit_name
  unit_name="$(systemd_unit_name)"
  local unit_path="/etc/systemd/system/${unit_name}"

  cat > "$unit_path" <<EOF
[Unit]
Description=Mount CIFS share ($CIFS_REMOTE)
Wants=network-online.target
After=network-online.target

[Mount]
What=$CIFS_REMOTE
Where=$MOUNTPOINT
Type=cifs
Options=credentials=/etc/cifs-credentials-import,_netdev,vers=$CIFS_VERS,iocharset=utf8,nofail

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$unit_name"
}

verify_mount() {
  echo
  echo "=== Verification ==="
  findmnt "$MOUNTPOINT" || true
  systemctl --no-pager status "$(systemd_unit_name)" || true
}

main() {
  require_root
  install_packages
  prompt_values
  write_credentials
  make_mountpoint
  write_systemd_unit
  verify_mount

  echo
  echo "CIFS mount setup complete."
}

main "$@"

