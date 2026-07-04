#!/usr/bin/env bash
# =============================================================================
#  install-oracle-wireguard.sh
# -----------------------------------------------------------------------------
#  Bootstrap a WireGuard VPN server on Ubuntu 22.04 / 24.04 designed for the
#  Oracle Cloud Always Free tier. Intended for personal use / gaming tunnels.
#
#  Idempotent:
#    - Keeps existing /etc/wireguard/server_*.key and /etc/wireguard/wg0.conf
#    - Does NOT print the server private key
#    - Relies on Oracle Security List for ingress filtering
#
#  Run as root: sudo bash install-oracle-wireguard.sh
# =============================================================================
set -euo pipefail

# ---- Constants ---------------------------------------------------------------
WG_IFACE="wg0"
WG_PORT="51820"
WG_SUBNET_CIDR="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1/24"
WG_DIR="/etc/wireguard"
WG_CLIENTS_DIR="${WG_DIR}/clients"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
SYSCTL_FILE="/etc/sysctl.d/99-wireguard.conf"
BACKUP_DIR="${WG_DIR}/backups"

# ---- Guards ------------------------------------------------------------------
if [[ ${EUID} -ne 0 ]]; then
  echo "[FATAL] This script must be run as root (sudo)." >&2
  exit 1
fi

# Make sure secrets we create are owner-readable only.
umask 077

mkdir -p "${WG_DIR}" "${WG_CLIENTS_DIR}" "${BACKUP_DIR}"
chmod 700 "${WG_DIR}" "${WG_CLIENTS_DIR}" "${BACKUP_DIR}"

# ---- Detect WAN interface ----------------------------------------------------
WAN_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')"
if [[ -z "${WAN_IFACE}" || "${WAN_IFACE}" == "unreachable" ]]; then
  echo "[FATAL] Could not detect WAN interface (ip route get 1.1.1.1 failed)." >&2
  exit 1
fi
echo "[INFO] Detected WAN interface: ${WAN_IFACE}"

# ---- Packages ----------------------------------------------------------------
echo "[STEP] Installing wireguard, qrencode, iptables..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  wireguard \
  qrencode \
  iptables \
  iptables-persistent \
  ca-certificates

# ---- IP forwarding -----------------------------------------------------------
echo "[STEP] Enabling IPv4 forwarding via ${SYSCTL_FILE}..."
cat > "${SYSCTL_FILE}" <<EOF
# WireGuard: IPv4 forwarding (managed by install-oracle-wireguard.sh)
net.ipv4.ip_forward=1
EOF
chmod 644 "${SYSCTL_FILE}"
sysctl -p "${SYSCTL_FILE}" >/dev/null

# ---- Server keys (keep if present) ------------------------------------------
SERVER_PRIV="${WG_DIR}/server_private.key"
SERVER_PUB="${WG_DIR}/server_public.key"

if [[ ! -s "${SERVER_PRIV}" || ! -s "${SERVER_PUB}" ]]; then
  echo "[STEP] Generating server keypair..."
  wg genkey | tee "${SERVER_PRIV}" | wg pubkey > "${SERVER_PUB}"
else
  echo "[INFO] Server keypair already exists; reusing."
fi
chmod 600 "${SERVER_PRIV}"
chmod 644 "${SERVER_PUB}"

# Read pubkey for the config (private key is read at startup; never printed)
SERVER_PUB_KEY="$(cat "${SERVER_PUB}")"

# ---- wg0.conf (keep if present) ---------------------------------------------
if [[ ! -s "${WG_CONF}" ]]; then
  echo "[STEP] Writing ${WG_CONF}..."
  # Secure umask for the file we are about to write.
  (umask 077 && cat > "${WG_CONF}" <<EOF
# WireGuard server config (managed by install-oracle-wireguard.sh)
# Do NOT commit this file to version control.
[Interface]
Address    = ${WG_SERVER_IP}
ListenPort = ${WG_PORT}
PrivateKey = $(cat "${SERVER_PRIV}")
# NAT egress traffic to the internet via the detected WAN interface
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET_CIDR} -o ${WAN_IFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET_CIDR} -o ${WAN_IFACE} -j MASQUERADE

# Peers are appended below by add-client.sh
EOF
  )
else
  echo "[INFO] ${WG_CONF} already exists; leaving untouched."
fi
chmod 600 "${WG_CONF}"

# ---- Bring up WireGuard ------------------------------------------------------
echo "[STEP] Enabling and starting wg-quick@${WG_IFACE}..."
systemctl enable --now "wg-quick@${WG_IFACE}"

# Best-effort: persist iptables rules so NAT survives reboot.
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

# ---- Oracle Security List checklist -----------------------------------------
PUBLIC_IP_V4="$(ip -4 addr show "${WAN_IFACE}" 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)"
[[ -z "${PUBLIC_IP_V4}" ]] && PUBLIC_IP_V4="<not-detected>"

cat <<EOF

==============================================================================
 WireGuard server is up.

 Server interface   : ${WG_IFACE}
 Listen port        : UDP ${WG_PORT}
 Subnet             : ${WG_SUBNET_CIDR}  (server ${WG_SERVER_IP})
 WAN interface      : ${WAN_IFACE}
 Server public IP   : ${PUBLIC_IP_V4}
 Server public key  : ${SERVER_PUB_KEY}
 Server private key : (not shown on purpose - kept in ${SERVER_PRIV}, mode 0600)

 Oracle Cloud checklist (REQUIRED for clients to reach this server):
   1. Open the OCI Console -> Networking -> Virtual Cloud Networks -> your VCN
   2. Subnets -> the regional subnet hosting this instance -> Security List
      -> Default Security List -> Add Ingress Rule:
          Source CIDR    : 0.0.0.0/0   (or your client public IPs for tighter scope)
          Protocol       : UDP
          Destination Port : 51820
   3. If your VNIC also has a Network Security Group, add the same UDP/51820
      rule there. OCI evaluates BOTH layers.
   4. Also verify the instance's iptables (Oracle Ubuntu images ship a default
      iptables rule; this script does NOT disable it). Confirm with:
          sudo iptables -L INPUT -n --line-numbers
      If traffic is silently dropped, add:
          iptables -I INPUT 1 -p udp --dport ${WG_PORT} -j ACCEPT
   5. Confirm UDP/${WG_PORT} inbound from a remote host:
          nc -uvz <public_ip> ${WG_PORT}

 Next steps:
   - Add a client: sudo bash scripts/wireguard/add-client.sh <name>
   - Show status : sudo bash scripts/wireguard/show-status.sh
   - Revoke      : sudo bash scripts/wireguard/revoke-client.sh <name>
==============================================================================
EOF