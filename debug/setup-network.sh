#!/usr/bin/env bash
#
# Create the isolated vmbr1 NAT layout on the Proxmox host. Run as root:
#   bash setup-network.sh
#
# Result: vmbr1 (no physical ports, host holds $HOST_IP), MASQUERADE of
# $SUBNET out via $UPLINK, DNAT forwards for SSH/dashboard/(optional)
# gateway into the Hermes container. Idempotent: safe to re-run.
# Every value can be overridden with env vars (see defaults below).

set -u

BRIDGE="${BRIDGE:-vmbr1}"
SUBNET="${SUBNET:-10.10.10.0/24}"
HOST_IP="${HOST_IP:-10.10.10.1}"
PREFIX="${PREFIX:-24}"
UPLINK="${UPLINK:-vmbr0}"
HERMES_IP="${HERMES_IP:-10.10.10.10}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
DASHBOARD_FWD_PORT="${DASHBOARD_FWD_PORT:-9119}"
GATEWAY_FWD_PORT="${GATEWAY_FWD_PORT:-}"
# ROUTED=1: LAN reaches containers via a static route on the LAN router
# (10.10.10.0/24 via the Proxmox host) instead of DNAT forwards. Only
# MASQUERADE (internet) is installed; proxy targets are direct .10/.11 IPs.
ROUTED="${ROUTED:-0}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the Proxmox host." >&2
  exit 1
fi

STANZA_FILE="/etc/network/interfaces.d/${BRIDGE}"

ensure_iptables() {
  # ensure_iptables <table> <rule...>: append only when missing
  local table="$1"
  shift
  if iptables -t "$table" -C "$@" 2>/dev/null; then
    echo "  [KEEP] iptables -t $table $*"
  else
    iptables -t "$table" -A "$@"
    echo "  [ADD ] iptables -t $table $*"
  fi
}

echo "== forwarding"
if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]]; then
  sysctl -w net.ipv4.ip_forward=1
fi
echo "  [OK  ] IPv4 forwarding on"

echo "== bridge ${BRIDGE}"
if ! grep -q "^source /etc/network/interfaces.d/" /etc/network/interfaces 2>/dev/null; then
  echo "source /etc/network/interfaces.d/*" >>/etc/network/interfaces
  echo "  [ADD ] sourced interfaces.d in /etc/network/interfaces"
fi
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  echo "  [KEEP] bridge $BRIDGE exists"
else
  cat >"$STANZA_FILE" <<EOF
auto ${BRIDGE}
iface ${BRIDGE} inet static
    address ${HOST_IP}/${PREFIX}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  ifup "$BRIDGE"
  echo "  [ADD ] bridge $BRIDGE with ${HOST_IP}/${PREFIX}"
fi
if bridge link show 2>/dev/null | grep -q "master ${BRIDGE}"; then
  echo "  [WARN] bridge $BRIDGE has enslaved ports; remove them to keep it isolated" >&2
fi

echo "== NAT (persisted via $STANZA_FILE post-up lines)"
PERSIST=(
  "post-up iptables -t nat -A POSTROUTING -s '${SUBNET}' -o ${UPLINK} -j MASQUERADE"
  "post-down iptables -t nat -D POSTROUTING -s '${SUBNET}' -o ${UPLINK} -j MASQUERADE"
)
if [[ "$ROUTED" != "1" ]]; then
  PERSIST+=(
    "post-up iptables -t nat -A PREROUTING -i ${UPLINK} -p tcp --dport ${SSH_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:22"
    "post-down iptables -t nat -D PREROUTING -i ${UPLINK} -p tcp --dport ${SSH_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:22"
    "post-up iptables -t nat -A PREROUTING -i ${UPLINK} -p tcp --dport ${DASHBOARD_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:9119"
    "post-down iptables -t nat -D PREROUTING -i ${UPLINK} -p tcp --dport ${DASHBOARD_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:9119"
  )
fi
if [[ -n "$GATEWAY_FWD_PORT" ]]; then
  PERSIST+=(
    "post-up iptables -t nat -A PREROUTING -i ${UPLINK} -p tcp --dport ${GATEWAY_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:${GATEWAY_FWD_PORT}"
    "post-down iptables -t nat -D PREROUTING -i ${UPLINK} -p tcp --dport ${GATEWAY_FWD_PORT} -j DNAT --to-destination ${HERMES_IP}:${GATEWAY_FWD_PORT}"
  )
fi
touch "$STANZA_FILE"
for line in "${PERSIST[@]}"; do
  if grep -qF "$line" "$STANZA_FILE" 2>/dev/null; then
    echo "  [KEEP] $line"
  else
    echo "    $line" >>"$STANZA_FILE"
    echo "  [ADD ] $line"
  fi
done

ensure_iptables nat POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
ensure_iptables filter FORWARD -i "$UPLINK" -o "$BRIDGE" -d "$SUBNET" -j ACCEPT
ensure_iptables filter FORWARD -i "$BRIDGE" -s "$SUBNET" -o "$UPLINK" -j ACCEPT
if [[ "$ROUTED" != "1" ]]; then
  ensure_iptables nat PREROUTING -i "$UPLINK" -p tcp --dport "$SSH_FWD_PORT" -j DNAT --to-destination "${HERMES_IP}:22"
  ensure_iptables nat PREROUTING -i "$UPLINK" -p tcp --dport "$DASHBOARD_FWD_PORT" -j DNAT --to-destination "${HERMES_IP}:9119"
fi
if [[ -n "$GATEWAY_FWD_PORT" ]]; then
  ensure_iptables nat PREROUTING -i "$UPLINK" -p tcp --dport "$GATEWAY_FWD_PORT" -j DNAT --to-destination "${HERMES_IP}:${GATEWAY_FWD_PORT}"
fi

echo
echo "done. Containers: vmbr1, 10.10.10.x/24, gateway ${HOST_IP}."
if [[ "$ROUTED" == "1" ]]; then
  echo "ROUTED mode: add this static route on your LAN router:"
  echo "  10.10.10.0/24 via <proxmox-lan-ip>"
  echo "Then from LAN, reach containers directly:"
  echo "  SSH:      ssh root@${HERMES_IP} (port 22, no forward needed)"
  echo "  Dashboard reverse-proxy target: http://${HERMES_IP}:9119"
  echo "(If the datacenter firewall is enabled, allow FORWARD ${UPLINK}<->${BRIDGE} there too.)"
else
  echo "SSH:      <proxmox-lan-ip>:${SSH_FWD_PORT} -> ${HERMES_IP}:22"
  echo "Dashboard reverse-proxy target: http://<proxmox-lan-ip>:${DASHBOARD_FWD_PORT}"
fi
