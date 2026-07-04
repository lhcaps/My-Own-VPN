#!/usr/bin/env bash
# =============================================================================
#  revoke-client.sh
# -----------------------------------------------------------------------------
#  Revoke a WireGuard peer:
#     - remove its [Peer] block from /etc/wireguard/wg0.conf
#     - apply the change live with `wg syncconf` (no handshake drops)
#     - move the client files under /etc/wireguard/clients/revoked/ for audit
#
#  Usage: sudo bash revoke-client.sh <client-name>
# =============================================================================
set -euo pipefail

WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/${WG_IFACE}.conf"
WG_CLIENTS_DIR="${WG_DIR}/clients"
WG_REVOKED_DIR="${WG_CLIENTS_DIR}/revoked"

if [[ $EUID -ne 0 ]]; then
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

CLIENT_PUB_FILE="${WG_CLIENTS_DIR}/${CLIENT_NAME}.pub"

if [[ -s "${CLIENT_PUB_FILE}" ]]; then
  CLIENT_PUB_KEY="$(cat "${CLIENT_PUB_FILE}")"
else
  echo "[FATAL] Public key file missing: ${CLIENT_PUB_FILE}" >&2
  echo "        Without it we cannot safely identify the peer in wg0.conf." >&2
  exit 1
fi

# ---- Mutate wg0.conf (drop the matching [Peer] block) ---------------------
# Blocks are separated by a blank line. A peer block has a PublicKey line.
# We preserve everything else verbatim.
LOCK_FILE="${WG_DIR}/.wg.lock"
exec 9>"${LOCK_FILE}"
flock -w 10 9 || { echo "[FATAL] Could not acquire ${LOCK_FILE}" >&2; exit 1; }

# Before rewriting, count how many times the target key appeared in the
# source. If it is zero, the .pub file disagrees with the actual config —
# refuse to proceed (we are about to delete files).
SRC_HITS="$(grep -cF "${CLIENT_PUB_KEY}" "${WG_CONF}" || true)"
if [[ "${SRC_HITS}" -eq 0 ]]; then
  echo "[FATAL] Peer ${CLIENT_PUB_KEY} not found in ${WG_CONF}." >&2
  echo "        The stored .pub key disagrees with the live configuration." >&2
  exit 1
fi

# Apply the awk block remover.
TMP_CONF="$(mktemp)"
chmod 600 "${TMP_CONF}"

# awk pass: scan the file. While inside a [Peer] ... blank-line block, skip
# it if its PublicKey matches the target. Drop the optional preceding
# "# Client: ..." comment that install-oracle-wireguard.sh / add-client.sh
# would have written.
#
# Implementation notes:
#   - "in_peer" is set when we see [Peer] and cleared at the next blank line.
#   - "dropping" becomes 1 if we matched the key inside that block.
#   - We buffer the optional leading comment line and only emit it if we
#     are NOT dropping the following block.
awk -v target="${CLIENT_PUB_KEY}" '
  BEGIN { in_peer = 0; dropping = 0; comment = "" }
  # Empty line: closes any [Peer] block in progress.
  /^[[:space:]]*$/ {
    if (in_peer) {
      in_peer = 0; dropping = 0; comment = ""
      # blank line acts as separator: only print a single blank line
      print
      next
    }
    print
    next
  }
  # A "# Client: ..." comment line. Buffer it; emit only with the next block.
  /^# Client: / {
    comment = $0
    next
  }
  # [Peer] header: start of a peer block. Decide whether to keep or skip
  # by looking at the next non-blank, non-comment line for the PublicKey.
  /^\[Peer\]/ {
    in_peer = 1
    dropping = 0
    saved_header = $0
    next
  }
  # PublicKey line: this is the first real key line in the block. If it
  # matches the target, mark the whole block for dropping.
  /^PublicKey[[:space:]]*=/ {
    if (in_peer) {
      key = $0
      sub(/^PublicKey[[:space:]]*=[[:space:]]*/, "", key)
      sub(/[[:space:]]*$/, "", key)
      if (key == target) {
        dropping = 1
        next
      }
      # First non-target block: emit comment + header + PublicKey, then
      # continue in normal mode for the rest of the block.
      if (comment != "") { print comment; comment = "" }
      print saved_header
      print
      next
    }
    print
    next
  }
  {
    # Other lines inside a peer block: emit only if not dropping.
    if (in_peer && dropping) next
    print
  }
  END {
    if (in_peer && !dropping && comment != "") print comment
  }
' "${WG_CONF}" > "${TMP_CONF}"

# Collapse runs of blank lines that the removal may have left.
awk '
  /^[[:space:]]*$/ { if (blank++) next; else { print; blank=1; next } }
  { blank=0; print }
' "${TMP_CONF}" > "${TMP_CONF}.c"
mv "${TMP_CONF}.c" "${TMP_CONF}"

# If we did not actually drop the key, abort (do not lose state).
if grep -qF "${CLIENT_PUB_KEY}" "${TMP_CONF}"; then
  echo "[FATAL] Peer block for target key not found in ${WG_CONF}." >&2
  rm -f "${TMP_CONF}"
  exit 1
fi

mv "${TMP_CONF}" "${WG_CONF}"
chmod 600 "${WG_CONF}"

# Apply live (no restart -> no handshake drops).
# File-based, not process substitution, so exit codes propagate.
# We tolerate `wg-quick strip` failure (it can fail if the previous
# configuration was already removed from the live interface), but
# `wg syncconf` MUST succeed — if it does not, the file on disk and the
# running config will disagree.
STRIP_OK=1
wg-quick strip "${WG_IFACE}" > "${WG_DIR}/.wg.strip.tmp" 2>/dev/null || STRIP_OK=0
if [[ ${STRIP_OK} -ne 1 ]]; then
  echo "[WARN] wg-quick strip produced no output; will still attempt syncconf." >&2
fi

if ! wg syncconf "${WG_IFACE}" "${WG_DIR}/.wg.strip.tmp" 2>/dev/null; then
  echo "[FATAL] wg syncconf failed. The peer is removed from ${WG_CONF} but" >&2
  echo "        may still be present in the live interface state. Investigate:" >&2
  echo "          sudo wg show ${WG_IFACE}" >&2
  echo "          sudo journalctl -u wg-quick@${WG_IFACE} -n 50 --no-pager" >&2
  rm -f "${WG_DIR}/.wg.strip.tmp"
  exit 1
fi
rm -f "${WG_DIR}/.wg.strip.tmp}"

if wg show "${WG_IFACE}" | grep -qF "${CLIENT_PUB_KEY}"; then
  echo "[WARN] Peer still present on the live interface. Verify with: wg show ${WG_IFACE}" >&2
fi

# ---- Archive client config -------------------------------------------------
mkdir -p "${WG_REVOKED_DIR}"
chmod 700 "${WG_REVOKED_DIR}"
TIMESTAMP="$(date -u +'%Y%m%dT%H%M%SZ')"

for ext in conf pub key; do
  src="${WG_CLIENTS_DIR}/${CLIENT_NAME}.${ext}"
  if [[ -f "${src}" ]]; then
    mv "${src}" "${WG_REVOKED_DIR}/${CLIENT_NAME}.${TIMESTAMP}.${ext}"
  fi
done
chmod 600 "${WG_REVOKED_DIR}/${CLIENT_NAME}.${TIMESTAMP}."* 2>/dev/null || true

cat <<EOF

[OK] Client '${CLIENT_NAME}' revoked.
     Public key removed from ${WG_CONF}.
     Files archived under ${WG_REVOKED_DIR}/ for audit (nothing deleted).
     Live reloaded via wg syncconf (no handshake drops).

To inspect the live state, run:  sudo bash scripts/wireguard/show-status.sh
EOF
