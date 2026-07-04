#!/usr/bin/env bash
# =============================================================================
#  add-client.sh
# -----------------------------------------------------------------------------
#  Add a new WireGuard peer (client) to the running server.
#  Allocates the next free IP in 10.8.0.0/24, writes a client config file
#  under /etc/wireguard/clients/ (chmod 600), applies the peer via
#  `wg syncconf` (no service restart, no handshake drops), and prints a QR
#  code on the terminal.
#
#  Usage: sudo bash add-client.sh <client-name>
# =============================================================================
set -euo pipefail

WG_IFACE="wg0"
WG_SUBNET_CIDR="10.8.0.0/24"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"

if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] This script must be run as root (sudo)." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo bash $0 <client-name>" >&2
  echo "Allowed characters: a-z A-Z 0-9 _ -" >&2
  exit 2
fi

CLIENT_NAME="$1"

# Validate client name strictly
if [[ ! "${CLIENT_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[FATAL] Invalid client name. Use only [a-zA-Z0-9_-]." >&2
  exit 2
fi
if [[ ${#CLIENT_NAME} -gt 32 ]]; then
  echo "[FATAL] Client name too long (max 32 chars)." >&2
  exit 2
fi

for f in "${WG_CONF}" "/usr/bin/wg" "/usr/bin/wg-quick" "/usr/bin/qrencode"; do
  if [[ ! -e "${f}" ]]; then
    echo "[FATAL] Missing prerequisite: ${f}" >&2
    echo "        Run install-oracle-wireguard.sh first." >&2
    exit 1
  fi
done

mkdir -p "${WG_CLIENTS_DIR}"
chmod 700 "${WG_CLIENTS_DIR}"

# Allocate next free .ip in 10.8.0.0/24 starting at .2 (.1 is the server)
USED_IPS="$(wg show "${WG_IFACE}" allowed-ips 2>/dev/null || true)"
USED_IPS+=$'\n'"${WG_SUBNET_CIDR}"  # include the subnet header itself

ALLOCATED_IP=""
for octet in $(seq 2 254); do
  candidate="10.8.0.${octet}"
  if ! grep -q -E "(^|[[:space:]])${candidate}(/[[:digit:]]+)?([[:space:]]|$)" <<<"${USED_IPS}"; then
    ALLOCATED_IP="${candidate}"
    break
  fi
done

if [[ -z "${ALLOCATED_IP}" ]]; then
  echo "[FATAL] No free IP addresses remaining in ${WG_SUBNET_CIDR}." >&2
  exit 1
fi

# Reject obvious re-add (same public key collision)
umask 077
CLIENT_PRIV="${WG_CLIENTS_DIR}/${CLIENT_NAME}.key"
CLIENT_PUB="${WG_CLIENTS_DIR}/${CLIENT_NAME}.pub"
CLIENT_CONF="${WG_CLIENTS_DIR}/${CLIENT_NAME}.conf"

if [[ -s "${CLIENT_CONF}" || -s "${CLIENT_PRIV}" ]]; then
  echo "[FATAL] Client '${CLIENT_NAME}' already has files in ${WG_CLIENTS_DIR}." >&2
  echo "        Use revoke-client.sh first or remove those files." >&2
  exit 1
fi

wg genkey | tee "${CLIENT_PRIV}" | wg pubkey > "${CLIENT_PUB}"
chmod 600 "${CLIENT_PRIV}" "${CLIENT_PUB}"

CLIENT_PUB_KEY="$(cat "${CLIENT_PUB}")"
SERVER_PUB_KEY="$(cat "${WG_DIR}/server_public.key")"
SERVER_ENDPOINT="$(
  # Pull the first global IPv4 address from the default route interface
  ip -4 addr show scope global 2>/dev/null \
    | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1
):51820"
[[ "${SERVER_ENDPOINT}" == ":51820" ]] && SERVER_ENDPOINT="<server-public-ip>:51820"

# ---- Append [Peer] to wg0.conf ---------------------------------------------
# Use a lock around fs writes to avoid concurrent add/revoke races.
LOCK_FILE="${WG_DIR}/.wg.lock"
exec 9>"${LOCK_FILE}"
flock -w 10 9 || { echo "[FATAL] Could not acquire ${LOCK_FILE}" >&2; exit 1; }

# Append peer block
{
  echo ""
  echo "# Client: ${CLIENT_NAME} (added $(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  echo "[Peer]"
  echo "PublicKey = ${CLIENT_PUB_KEY}"
  echo "AllowedIPs = ${ALLOCATED_IP}/32"
} >> "${WG_CONF}"
chmod 600 "${WG_CONF}"

# Apply live without restarting the interface (no handshake drops).
# Use a file (not process substitution) so exit codes propagate under
# `set -euo pipefail`.
wg-quick strip "${WG_IFACE}" 2>/dev/null > "${WG_DIR}/.wg.strip.tmp"
if ! wg syncconf "${WG_IFACE}" "${WG_DIR}/.wg.strip.tmp"; then
  echo "[FATAL] wg syncconf failed; the peer was appended to ${WG_CONF}" >&2
  echo "        but not applied to the live interface. Investigate with:" >&2
  echo "          sudo wg show ${WG_IFACE}" >&2
  echo "          sudo journalctl -u wg-quick@${WG_IFACE} -n 50 --no-pager" >&2
  rm -f "${WG_DIR}/.wg.strip.tmp"
  exit 1
fi
rm -f "${WG_DIR}/.wg.strip.tmp"

# ---- Write client config ---------------------------------------------------
cat > "${CLIENT_CONF}" <<EOF
# WireGuard client config for: ${CLIENT_NAME}
# Generated $(date -u +'%Y-%m-%dT%H:%M:%SZ') — DO NOT commit this file.
[Interface]
PrivateKey = $(cat "${CLIENT_PRIV}")
Address    = ${ALLOCATED_IP}/32
DNS        = 1.1.1.1
MTU        = 1380

[Peer]
PublicKey  = ${SERVER_PUB_KEY}
Endpoint   = ${SERVER_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "${CLIENT_CONF}"

# ---- Output ----------------------------------------------------------------
cat <<EOF

[OK] Client '${CLIENT_NAME}' added.
     IP  : ${ALLOCATED_IP}
     Pub : ${CLIENT_PUB_KEY}
     Cfg : ${CLIENT_CONF}

Scan the QR code below with the WireGuard mobile app, or copy the file:

EOF
qrencode -t ansiutf8 < "${CLIENT_CONF}" || echo "(qrencode failed; config is in ${CLIENT_CONF})"
echo ""
echo "Import into WireGuard Windows:  copy ${CLIENT_CONF} to your PC and open it in the WireGuard app."
