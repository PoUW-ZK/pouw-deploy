#!/usr/bin/env bash
# Prepares the secret files for docker compose (secrets:) according to secrets.list.
#
#   SECRETS_SOURCE=local  (default) random passwords in ./.secrets, created only once
#   SECRETS_SOURCE=pass   server: decrypts passwords from pass into SECRETS_DIR (tmpfs)
#
# No values are ever printed. Runs before every `docker compose up`
# and at server start (systemd pouw-secrets.service).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_="${SECRETS_SOURCE:-local}"
dir="${SECRETS_DIR:-$root/.secrets}"
case "$dir" in /*) ;; *) dir="$root/$dir" ;; esac

umask 077
mkdir -p "$dir"
chmod 700 "$dir"

# The files are world-readable because they are mounted into containers with other
# UIDs (Grafana 472, Jenkins 1000). On the host they are protected by the 700 directory.
write() {
    local file="$dir/$1" tmp
    tmp="$(mktemp "$dir/.tmp.XXXXXX")"
    cat >"$tmp"
    chmod 444 "$tmp"
    mv -f "$tmp" "$file"
}

missing=()
while read -r name path kind; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    case "$kind" in
        ssh-key)
            if [[ ! -s "$dir/$name" ]]; then
                rm -f "$dir/$name" "$dir/$name.pub"
                ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$dir/$name"
                chmod 444 "$dir/$name" "$dir/$name.pub"
            fi
            ;;
        random | manual)
            if [[ "$source_" == pass ]]; then
                if pass show "$path" >/dev/null 2>&1; then
                    # no trailing newline, otherwise it would become part of the password
                    printf '%s' "$(pass show "$path")" | write "$name"
                else
                    missing+=("$path")
                    [[ -e "$dir/$name" ]] || printf '' | write "$name"
                fi
            elif [[ ! -e "$dir/$name" ]]; then
                if [[ "$kind" == random ]]; then
                    openssl rand -hex 24 | tr -d '\n' | write "$name"
                else
                    # GitHub is not used locally (JENKINS_AUTH=local)
                    printf '' | write "$name"
                fi
            fi
            ;;
        *)
            echo "secrets.list: unknown kind '$kind' for $name" >&2
            exit 1
            ;;
    esac
done <"$root/secrets.list"

if ((${#missing[@]})); then
    echo "Missing in pass (services get an empty value):" >&2
    printf '  pass insert -m %s\n' "${missing[@]}" >&2
fi
echo "Secrets ready in $dir"
