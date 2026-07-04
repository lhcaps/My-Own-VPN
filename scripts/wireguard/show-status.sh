#!/usr/bin/env bash
# =============================================================================
#  show-status.sh
# -----------------------------------------------------------------------------
#  Quick operator view: handshake freshness, RX/TX totals, listen port,
#  IPv4 forwarding, WAN interface, and a UDP/51820 listening-socket check.
#
#  Usage: sudo bash show-status.sh
# =============================================================================
set -euo pipefail

WG_IFACE="${WG_IFACE:-wg0}"

if [[ ${EUID} -ne 0 ]]; then
  echo "[NOTE] Re-running as root for full visibility..." >&2
  exec sudo bash "$0"
fi

if ! command -v wg >/dev/null 2>&1; then
  echo "[FATAL] wireguard-tools not installed (missing 'wg')." >&2
  echo "        Run install-oracle-wireguard.sh first." >&2
  exit 1
fi

WAN_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
[[ -z "${WAN_IFACE}" ]] && WAN_IFACE="(unreachable)"

IP_FORWARD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "(?)")"
LISTEN_PORT="$(wg show "${WG_IFACE}" listen-port 2>/dev/null || true)"
[[ -z "${LISTEN_PORT}" ]] && LISTEN_PORT="(not running)"

printf '%-32s : %s\n' "WireGuard interface"        "${WG_IFACE}"
printf '%-32s : %s\n' "Listen port (UDP)"          "${LISTEN_PORT}"
printf '%-32s : %s\n' "WAN interface (MASQUERADE)" "${WAN_IFACE}"
printf '%-32s : %s\n' "net.ipv4.ip_forward"        "${IP_FORWARD}"
printf '%-32s : %s\n' "Server public key" \
  "$(cat /etc/wireguard/server_public.key 2>/dev/null || echo "(missing)")"

echo ""
echo "--- Active peers ------------------------------------------------------"
if wg show "${WG_IFACE}" >/dev/null 2>&1; then
  wg show "${WG_IFACE}" | sed 's/^/  /'
else
  echo "  (wg-quick@${WG_IFACE} is not up)"
fi

echo ""
echo "--- Quick handshake freshness ----------------------------------------"
# Use wg dump for a single, machine-readable pass over every peer.
# Field layout (after the interface line): pubkey  psk  endpoint  allowed-ips
#   latest-handshake-epoch  rx  tx  keepalive
NOW_EPOCH="$(date +%s)"

DUMP="$(wg show "${WG_IFACE}" dump 2>/dev/null || true)"
PEERS="$(printf '%s\n' "${DUMP}" | awk 'NR > 1 && NF >= 7')"

if [[ -n "${PEERS}" ]]; then
  echo "  (peers currently handshaked within the last ~2 minutes):"
  # shellcheck disable=SC2034  # psk, ep, keep intentionally unused; only age/rx/tx are reported
  printf '%s\n' "${PEERS}" | while IFS=$'\t' read -r pub psk ep allowed hs rx tx keep; do
    if [[ -n "${hs}" && "${hs}" != "0" ]]; then
      age="$((NOW_EPOCH - hs))"
      printf "  %s..  allowed=%s  age=%ss  rx=%sB  tx=%sB\n" \
        "${pub:0:20}" "${allowed}" "${age}" "${rx}" "${tx}"
    fi
  done
else
  echo "  (no active handshakes)"
fi

echo ""
echo "--- Listening sockets on UDP/${LISTEN_PORT} --------------------------"
if [[ "${LISTEN_PORT}" =~ ^[0-9]+$ ]]; then
  if command -v ss >/dev/null 2>&1; then
    ss -lun "sport = :${LISTEN_PORT}" 2>/dev/null | sed 's/^/  /' || true
  else
    echo "  (ss not available; install iproute2)"
  fi
else
  echo "  (WireGuard is not listening)"
fi

echo ""
echo "--- NAT (PostUp) sanity check -----------------------------------------"
NAT_RULE="$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -E '10\.8\.0\.0/24.*MASQUERADE' || true)"
if [[ -n "${NAT_RULE}" ]]; then
  echo "  OK  : ${NAT_RULE}"
else
  echo "  MISS: no MASQUERADE rule for 10.8.0.0/24 - clients will have no internet."
fi