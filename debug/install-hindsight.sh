#!/usr/bin/env bash
#
# Unattended Hindsight LXC install on the Proxmox host. Run as root:
#   bash install-hindsight.sh
#
# Bakes in every Advanced setting (no wizard): CT 110 'hindsight' on vmbr1
# as 10.10.10.15/24, gateway 10.10.10.1, AdGuard DNS, lan.b13kjack.uk search
# domain, TUN on, FUSE/mknod/GPU off, protection on, Europe/Warsaw.
# Root SSH keys installed: the key below plus any host-found public keys.
# The ct/ script is fetched cache-busted and verified before executing,
# so a stale CDN copy can never silently install the wrong version.
#
# Env overrides: DESTROY_EXISTING=1 wipes CT 110 first (default: abort if
# it exists). All VAR_* below can be overridden the same way.

set -u

CTID="${CTID:-110}"
DESTROY_EXISTING="${DESTROY_EXISTING:-0}"
BRANCH="${BRANCH:-hermes-debian14-hindsight}"
BASE_URL="https://raw.githubusercontent.com/b13kjack/ProxmoxVE/${BRANCH}"

# Owner's public key: authorized for root in the new container.
OWNER_SSH_KEY="${OWNER_SSH_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIUYX9scx+ti1TZXUx6w8Znovx7b8xAPtd7vUhZDn/EK b13kjack}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the Proxmox host." >&2
  exit 1
fi

if pct status "$CTID" >/dev/null 2>&1; then
  if [[ "$DESTROY_EXISTING" == "1" ]]; then
    echo "Destroying existing CT $CTID..."
    pct stop "$CTID" 2>/dev/null || true
    pct destroy "$CTID"
  else
    echo "CT $CTID already exists. Re-run with DESTROY_EXISTING=1 to wipe it first." >&2
    exit 2
  fi
fi

# Root keys for the container: owner's key plus host-found public keys.
ALL_KEYS="$OWNER_SSH_KEY"
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    [[ "$line" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2|sk-) ]] && ALL_KEYS+=$'\n'"$line"
  done <"$f"
done < <(cat /root/.ssh/*.pub /root/.ssh/authorized_keys 2>/dev/null)
ALL_KEYS="$(printf '%s\n' "$ALL_KEYS" | sort -u)"

TMP_CT="$(mktemp)"
if ! curl -fsSL "${BASE_URL}/ct/hindsight.sh?cb=$(date +%s)" -o "$TMP_CT"; then
  echo "Could not download ct/hindsight.sh from $BASE_URL" >&2
  exit 3
fi
if ! grep -q '_UPSTREAM_BASE=' "$TMP_CT"; then
  echo "Downloaded ct/hindsight.sh is stale (missing fork URL override). Aborting." >&2
  exit 4
fi
bash -n "$TMP_CT" || exit 5

export MODE=1
export PHS_SILENT=1
export var_ctid="$CTID"
export var_hostname="hindsight"
export var_cpu="4"
export var_ram="8192"
export var_disk="25"
export var_brg="vmbr1"
export var_net="10.10.10.15/24"
export var_gateway="10.10.10.1"
export var_ns="192.168.1.5"
export var_searchdomain="lan.b13kjack.uk"
export var_ipv6_method="none"
export var_timezone="Europe/Warsaw"
export var_tun="yes"
export var_fuse="no"
export var_keyctl="1"
export var_mknod="0"
export var_gpu="no"
export var_protection="yes"
export var_verbose="yes"
export var_ssh="yes"
export var_ssh_authorized_key="$ALL_KEYS"

bash "$TMP_CT"
