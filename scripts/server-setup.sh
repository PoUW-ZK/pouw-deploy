#!/usr/bin/env bash
# Prepares the server (Ubuntu 24.04) for pouw-deploy. Run from your own account via sudo:
#
#   sudo ./scripts/server-setup.sh
#
# Safe to re-run. Does not change SSH, the firewall or users, that is handled in #10.
set -euo pipefail

if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
    echo "Run via sudo from your own account: sudo $0" >&2
    exit 1
fi

user="$SUDO_USER"
root="$(cd "$(dirname "$0")/.." && pwd)"
secrets_dir=/run/pouw-secrets

apt-get update -q
apt-get install -y -q pass gnupg make git openssl
if ! command -v docker >/dev/null; then
    apt-get install -y -q docker.io docker-compose-v2
fi
systemctl enable --now docker
usermod -aG docker "$user"

# tmpfs directory for secrets, recreated after a server reboot
cat >/etc/tmpfiles.d/pouw.conf <<EOF
d $secrets_dir 0700 $user $user -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/pouw.conf

# Secrets are decrypted before Docker starts, so containers with
# restart: unless-stopped find their files after a server reboot
cat >/etc/systemd/system/pouw-secrets.service <<EOF
[Unit]
Description=PoUW: secrets from pass for docker compose
After=local-fs.target systemd-tmpfiles-setup.service
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Environment=SECRETS_SOURCE=pass SECRETS_DIR=$secrets_dir
ExecStart=$root/scripts/secrets.sh

[Install]
WantedBy=docker.service
EOF
systemctl daemon-reload
systemctl enable pouw-secrets.service

echo
echo "Done. Next, as $user (after logging in again for the docker group):"
echo "  cp .env.example .env && nano .env"
echo "  ./scripts/pass-init.sh"
echo "  make up"
