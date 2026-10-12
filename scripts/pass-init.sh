#!/usr/bin/env bash
# First-time pass setup on the server. Run as the user the network runs under.
# Safe to re-run: existing keys and passwords are left untouched.
#
#   ./scripts/pass-init.sh [ADMIN_GPG_ID ...]
#
# 1. Creates a server GPG key without a passphrase, so deploys and restarts run
#    without a human. It is protected only by access to this account on the server.
# 2. Encrypts the store for the server key and the admins' keys (import their
#    public keys first: gpg --import admin.asc), so an admin can restore a backup
#    of the store even without the server.
# 3. Generates the random-kind passwords from secrets.list that are not in pass yet.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
uid="PoUW server ($(hostname)) <pouw@$(hostname)>"

if ! gpg --list-secret-keys "$uid" >/dev/null 2>&1; then
    echo "Creating server GPG key: $uid"
    gpg --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "$uid" default default never
fi
server_fpr="$(gpg --list-secret-keys --with-colons "$uid" | awk -F: '$1 == "fpr" { print $10; exit }')"

recipients=("$server_fpr")
for id in "$@"; do
    fpr="$(gpg --list-keys --with-colons "$id" | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ -z "$fpr" ]]; then
        echo "Public key '$id' is not imported (gpg --import ...)" >&2
        exit 1
    fi
    # pass needs the admins' keys marked as trusted
    echo "$fpr:6:" | gpg --import-ownertrust
    recipients+=("$fpr")
done

# pass init re-encrypts the whole store when the recipients change
pass init "${recipients[@]}"
[[ -d "${PASSWORD_STORE_DIR:-$HOME/.password-store}/.git" ]] || pass git init

manual=()
while read -r name path kind; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    pass show "$path" >/dev/null 2>&1 && continue
    case "$kind" in
        random) pass generate --no-symbols "$path" 32 >/dev/null && echo "Generated: $path" ;;
        manual) manual+=("$path") ;;
    esac
done <"$root/secrets.list"

echo
echo "Server key: $server_fpr"
if ((${#manual[@]})); then
    echo "Still to insert by hand (steps in the README, GitHub section):"
    printf '  pass insert -m %s\n' "${manual[@]}"
fi
