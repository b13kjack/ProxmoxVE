#!/usr/bin/env bash
#
# Test the isolated vmbr1 NAT layout for the Hermes/Hindsight containers.
# Run as root on the Proxmox host:
#   bash test-network.sh [HERMES_CTID [HINDSIGHT_CTID]]
#
# Every value can be overridden with env vars (see defaults below).
# Exit code = number of failed checks (0 = all green).

set -u

BRIDGE="${BRIDGE:-vmbr1}"
SUBNET="${SUBNET:-10.10.10.0/24}"
HOST_IP="${HOST_IP:-10.10.10.1}"
UPLINK="${UPLINK:-vmbr0}"
HERMES_CT="${1:-${HERMES_CT:-}}"
HINDSIGHT_CT="${2:-${HINDSIGHT_CT:-}}"
HERMES_IP="${HERMES_IP:-10.10.10.10}"
HINDSIGHT_IP="${HINDSIGHT_IP:-10.10.10.11}"
ADGUARD_IP="${ADGUARD_IP:-}"
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"
ROUTED="${ROUTED:-0}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
section() { echo "== $1"; }

tcp_open() { timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

section "host bridge ${BRIDGE}"
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  pass "bridge $BRIDGE exists"
else
  fail "bridge $BRIDGE missing"
fi
if ! command -v bridge >/dev/null 2>&1; then
  echo "  [SKIP] 'bridge' tool missing on host"
elif bridge link show 2>/dev/null | grep -q "master ${BRIDGE}"; then
  fail "bridge $BRIDGE has enslaved ports (should be isolated)"
else
  pass "bridge $BRIDGE has no physical ports (isolated)"
fi
if ip -4 addr show "$BRIDGE" 2>/dev/null | grep -q "$HOST_IP"; then
  pass "host holds $HOST_IP on $BRIDGE"
else
  fail "host has no $HOST_IP on $BRIDGE"
fi
if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]]; then
  pass "IPv4 forwarding enabled"
else
  fail "IPv4 forwarding disabled"
fi

section "NAT + SSH forward"
if iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE 2>/dev/null; then
  pass "MASQUERADE $SUBNET -> $UPLINK present"
else
  fail "MASQUERADE $SUBNET -> $UPLINK missing"
fi
if [[ "$ROUTED" == "1" ]]; then
  echo "  [SKIP] ROUTED mode: no DNAT expected (LAN uses static route)"
elif iptables -t nat -C PREROUTING -i "$UPLINK" -p tcp --dport "$SSH_FWD_PORT" -j DNAT --to-destination "${HERMES_IP}:22" 2>/dev/null; then
  pass "DNAT ${UPLINK}:${SSH_FWD_PORT} -> ${HERMES_IP}:22 present"
else
  fail "DNAT ${UPLINK}:${SSH_FWD_PORT} -> ${HERMES_IP}:22 missing"
fi

check_ct() {
  local ctid="$1" expect_ip="$2" label="$3"
  section "container $label (CT $ctid, expect $expect_ip)"
  if [[ -z "$ctid" ]]; then
    echo "  [SKIP] no CTID given"
    return
  fi
  if pct status "$ctid" 2>/dev/null | grep -q running; then
    pass "CT $ctid running"
  else
    fail "CT $ctid not running"
    return
  fi
  if pct exec "$ctid" -- ip -4 addr show 2>/dev/null | grep -q "$expect_ip"; then
    pass "CT $ctid holds $expect_ip"
  else
    fail "CT $ctid has no $expect_ip"
  fi
  if ping -c2 -W2 "$expect_ip" >/dev/null 2>&1; then
    pass "host can ping $expect_ip"
  else
    fail "host cannot ping $expect_ip"
  fi
  if pct exec "$ctid" -- ping -c2 -W3 1.1.1.1 >/dev/null 2>&1; then
    pass "CT $ctid reaches internet (1.1.1.1)"
  else
    fail "CT $ctid has no internet via NAT"
  fi
  if pct exec "$ctid" -- getent hosts github.com >/dev/null 2>&1; then
    pass "CT $ctid resolves DNS (github.com)"
  else
    fail "CT $ctid DNS resolution broken"
  fi
  if [[ -n "$ADGUARD_IP" ]]; then
    if pct exec "$ctid" -- grep -q "nameserver ${ADGUARD_IP}" /etc/resolv.conf 2>/dev/null; then
      pass "CT $ctid uses AdGuard $ADGUARD_IP"
    else
      fail "CT $ctid resolv.conf lacks nameserver $ADGUARD_IP"
    fi
    if pct exec "$ctid" -- command -v nslookup >/dev/null 2>&1; then
      if pct exec "$ctid" -- nslookup github.com "$ADGUARD_IP" >/dev/null 2>&1; then
        pass "CT $ctid queries AdGuard directly"
      else
        fail "CT $ctid cannot query AdGuard $ADGUARD_IP"
      fi
    elif pct exec "$ctid" -- command -v dig >/dev/null 2>&1; then
      if pct exec "$ctid" -- dig +short +time=3 +tries=1 github.com "@${ADGUARD_IP}" >/dev/null 2>&1; then
        pass "CT $ctid queries AdGuard directly"
      else
        fail "CT $ctid cannot query AdGuard $ADGUARD_IP"
      fi
    else
      echo "  [SKIP] no nslookup/dig in CT $ctid (apt install dnsutils for direct-AdGuard check)"
    fi
  else
    echo "  [SKIP] ADGUARD_IP unset, skipping AdGuard checks"
  fi
}

check_ct "$HERMES_CT" "$HERMES_IP" "hermes"
check_ct "$HINDSIGHT_CT" "$HINDSIGHT_IP" "hindsight"

if [[ -n "$HERMES_CT" && -n "$HINDSIGHT_CT" ]]; then
  section "container-to-container over $BRIDGE"
  if pct exec "$HERMES_CT" -- ping -c2 -W2 "$HINDSIGHT_IP" >/dev/null 2>&1; then
    pass "hermes -> hindsight ($HINDSIGHT_IP)"
  else
    fail "hermes cannot reach hindsight ($HINDSIGHT_IP)"
  fi
  if pct exec "$HERMES_CT" -- true 2>/dev/null && tcp_open "$HINDSIGHT_IP" 8888; then
    pass "Hindsight API ${HINDSIGHT_IP}:8888 reachable from host"
  else
    fail "Hindsight API ${HINDSIGHT_IP}:8888 not reachable from host"
  fi
fi

if [[ -n "$HERMES_CT" ]]; then
  section "SSH into hermes"
  if pct exec "$HERMES_CT" -- ss -ltn 2>/dev/null | grep -q ':22 '; then
    pass "sshd listening on :22 in hermes"
  else
    fail "sshd not listening on :22 in hermes"
  fi
  if tcp_open "$HERMES_IP" 22; then
    pass "port 22 open on $HERMES_IP"
  else
    fail "port 22 closed on $HERMES_IP"
  fi
  echo "  [INFO] DNAT from LAN cannot be tested from this host; run from a LAN machine:"
  echo "         nc -z -w3 <proxmox-lan-ip> $SSH_FWD_PORT"
fi

echo
echo "result: $PASS passed, $FAIL failed"
exit "$FAIL"
