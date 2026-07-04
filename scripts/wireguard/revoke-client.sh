#!/usr/bin/env bash
# =============================================================================
#  revoke-client.sh
# -----------------------------------------------------------------------------
#  Revoke a WireGuard peer:
#     - backup /etc/wireguard/wg0.conf to /etc/wireguard/backups/
#     - remove its [Peer] block from /etc/wireguard/wg0.conf (atomic write)
#     - apply the change live with `wg syncconf wg0 <(wg-quick strip wg0)`
#     - move the client files under /etc/wireguard/clients/revoked/
#
#  Usage: sudo bash revoke-client.sh <client-name>
# =============================================================================
set -euo pipefail

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"
WG_BACKUP_DIR="${WG_DIR}/backups"
WG_REVOKED_DIR="${WG_CLIENTS_DIR}/revoked"
LOCK_FILE="${WG_DIR}/.wg.lock"

if [[ ${EUID} -ne 0 ]]; then
  echo "[FATAL] This script must be run as root (sudo)." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: sudo bash $0 <client-name>" >&2
  exit 2
fi

CLIENT_NAME="$1"

if [[ ! "${CLIENT_NAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[FATAL] Invalid client name. Use only [a-zA-Z0-9_-]." >&2
  exit 2
fi

for f in "${WG_CONF}" "/usr/bin/wg" "/usr/bin/wg-quick" "/usr/bin/awk"; do
  [[ -e "${f}" ]] || { echo "[FATAL] Missing prerequisite: ${f}" >&2; exit 1; }
done

umask 077

CLIENT_PUB_FILE="${WG_CLIENTS_DIR}/${CLIENT_NAME}.pub"

if [[ -s "${CLIENT_PUB_FILE}" ]]; then
  CLIENT_PUB_KEY="$(cat "${CLIENT_PUB_FILE}")"
else
  echo "[FATAL] Public key file missing: ${CLIENT_PUB_FILE}" >&2
  echo "        Without it we cannot safely identify the peer in wg0.conf." >&2
  exit 1
fi

# ---- Mutate wg0.conf under a lock -------------------------------------------
exec 9>"${LOCK_FILE}"
flock -w 10 9 || { echo "[FATAL] Could not acquire ${LOCK_FILE}" >&2; exit 1; }

# Verify the source still references the key.
SRC_HITS="$(grep -cF "${CLIENT_PUB_KEY}" "${WG_CONF}" || true)"
if [[ "${SRC_HITS}" -eq 0 ]]; then
  echo "[FATAL] Peer ${CLIENT_PUB_KEY} not found in ${WG_CONF}." >&2
  echo "        The stored .pub key disagrees with the live configuration." >&2
  exit 1
fi

mkdir -p "${WG_BACKUP_DIR}" "${WG_REVOKED_DIR}"
chmod 700 "${WG_BACKUP_DIR}" "${WG_REVOKED_DIR}"

# Backup before mutation.
TS="$(date -u +'%Y%m%dT%H%M%SZ')"
BACKUP_FILE="${WG_BACKUP_DIR}/wg0.conf.${TS}"
cp -p "${WG_CONF}" "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"

# Use awk to drop the matching [Peer] block (and any "# Client: ..." comment
# that immediately precedes it). State machine:
#   - in_peer=1 once we cross a [Peer] header
#   - dropping=1 once we see the target PublicKey inside that block
#   - the optional "# Client: ..." comment is buffered and emitted only
#     with the following kept block
TMP_CONF="$(mktemp)"
chmod 600 "${TMP_CONF}"

awk -v target="${CLIENT_PUB_KEY}" '
  BEGIN { in_peer = 0; dropping = 0; comment = "" }
  /^[[:space:]]*$/ {
    if (in_peer) { in_peer = 0; dropping = 0; comment = ""; print; next }
    print; next
  }
  /^# Client: / { comment = $0; next }
  /^\[Peer\]/    { in_peer = 1; dropping = 0; saved_header = $0; next }
  /^PublicKey[[:space:]]*=/ {
    if (in_peer) {
      key = $0
      sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", key)
      sub(/[[:space:]]*$/, "", key)
      if (key == target) { dropping = 1; next }
      if (comment != "") { print comment; comment = "" }
      print saved_header
      print
      next
    }
    print; next
  }
  { if (in_peer && dropping) next; print }
  END { if (in_peer && !dropping && comment != "") print comment }
' "${WG_CONF}" > "${TMP_CONF}"

# Collapse runs of blank lines left behind.
awk '
  /^[[:space:]]*$/ { if (blank++) next; else { print; blank=1; next } }
  { blank=0; print }
' "${TMP_CONF}" > "${TMP_CONF}.c"
mv "${TMP_CONF}.c" "${TMP_CONF}"

# Post-condition: target key must be gone from the rewritten config.
if grep -qF "${CLIENT_PUB_KEY}" "${TMP_CONF}"; then
  echo "[FATAL] Peer block for target key not found in ${WG_CONF}." >&2
  echo "        Rewritten config still contains the key; aborting." >&2
  echo "        Original wg0.conf is preserved at ${BACKUP_FILE}." >&2
  rm -f "${TMP_CONF}"
  exit 1
fi

mv "${TMP_CONF}" "${WG_CONF}"
chmod 600 "${WG_CONF}"

# Apply live (no restart -> no handshake drops).
# Process substitution does NOT propagate exit codes under `set -e`, so we
# explicitly wait on $!. See wireguard-tools commit 26683f6c.
if ! wg syncconf "${WG_IFACE}" <(wg-quick strip "${WG_IFACE}"); then
  echo "[FATAL] wg syncconf failed. The peer is removed from ${WG_CONF} but" >&2
  echo "        may still be present in the live interface state." >&2
  echo "        Original config preserved at ${BACKUP_FILE}." >&2
  echo "        Investigate:" >&2
  echo "          sudo wg show ${WG_IFACE}" >&2
  echo "          sudo journalctl -u wg-quick@${WG_IFACE} -n 50 --no-pager" >&2
  exit 1
fi
wait $!

if wg show "${WG_IFACE}" | grep -qF "${CLIENT_PUB_KEY}"; then
  echo "[WARN] Peer still present on the live interface. Verify with: wg show ${WG_IFACE}" >&2
fi

# ---- Archive client files ---------------------------------------------------
for ext in conf pub key; do
  src="${WG_CLIENTS_DIR}/${CLIENT_NAME}.${ext}"
  if [[ -f "${src}" ]]; then
    mv "${src}" "${WG_REVOKED_DIR}/${CLIENT_NAME}.${TS}.${ext}"
  fi
done
chmod 600 "${WG_REVOKED_DIR}/${CLIENT_NAME}.${TS}."* 2>/dev/null || true

cat <<EOF

[OK] Client '${CLIENT_NAME}' revoked.
     Public key removed from ${WG_CONF}.
     Backup of original wg0.conf: ${BACKUP_FILE}
     Files archived under ${WG_REVOKED_DIR}/ for audit (nothing deleted).
     Live reloaded via wg syncconf (no handshake drops).

To inspect the live state, run:  sudo bash scripts/wireguard/show-status.sh
EOF