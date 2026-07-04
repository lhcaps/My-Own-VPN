# Security

This document covers three things, in order:

1. Things you must **never** put into this repository.
2. Things you should not **do** with the VPN once it's running.
3. Operational hygiene to keep the server tight.

---

## 1. Never commit secrets

The repo's `.gitignore` already excludes the obvious patterns. Honour
them. In particular, **do not** commit any of the following:

| Type                                         | Why                                |
|----------------------------------------------|------------------------------------|
| `*.key`, `*.priv`, `*.keypair`               | WireGuard private keys             |
| `wg0.conf`, any `*.conf` under `/etc/wireguard/` | Active server / client config  |
| Anything under `clients/`                     | Real client configs (have privkey) |
| Oracle API key PEMs (`*oci-api-key*.pem`, `api-key*.pem`) | Cloud credentials |
| OCIDs, tenancy IDs, user OCIDs               | Account identifiers               |
| Any file containing `BEGIN PRIVATE KEY`, `BEGIN RSA`, `BEGIN OPENSSH` | private material |
| `.env`, `.envrc`, `*.env*`                   | Generic env-file secrets           |
| `iptables-save.txt`, `*.tfstate`             | May include internal IPs/hostnames |
| Screenshots showing server's public IP, QR code, or peer keys |  anything in the screenshot is leaked |

If you accidentally commit a secret, **rotating** the key is the only real
remediation. `git filter-repo` or BFG can rewrite history, but the secret
should be considered compromised the moment it hits GitHub regardless —
GitHub's secret-scanning and external crawlers will have already seen it.

Rotate immediately:

- **WireGuard:** generate a new server keypair (`wg genkey | wg pubkey`),
  reissue every peer via `add-client.sh`, then revoke the old ones.
- **Oracle:** revoke the API key in Identity → Users → API Keys and
  create a new one.
- **Anything else:** change the password, revoke the token.

---

## 2. Don't do these things with the VPN

This is not a moral lecture — it's about what gets you into trouble:

- **Evade game-region locks.** Most competitive games explicitly forbid
  playing from data-center IP ranges. They will issue bans and may
  escalate to hardware bans.
- **Evade age verification.** Adult services and similar will geo-route
  you to wherever your exit IP lives. Using a VPN to lie about your
  region for this is fraud in many jurisdictions.
- **Re-join after a ban.** The game's anti-fraud system sees your
  Oracle IP, not your home IP. They correlate accounts, not IPs.
- **Bypass anti-cheat.** Anti-cheat detects WireGuard-shaped packets
  and known cloud IP ranges. You will get flagged.
- **Buy limited drops via spoofed regions.** This is also fraud.

This stack is for: personal privacy on hostile networks (hotels, coffee
shops), routing traffic through a region where you have a legitimate
reason to be, locking down telemetry on devices you own.

---

## 3. Operational hygiene

A few low-effort wins once the server is running.

### Lock down the OCI Security List

- Open **only**:
  - TCP 22 from your home IP `/32` (or your jump host).
  - UDP 51820 from `0.0.0.0/0` (or your home IP, if static).
- Remove the default SSH-from-anywhere rule as soon as you have your
  jump IP.

### File permissions

- Server private key: `chmod 600 /etc/wireguard/server_private.key`.
- `wg0.conf`: `chmod 600`.
- Client configs: `chmod 600`.
- `/etc/wireguard/` and `/etc/wireguard/clients/`: `chmod 700`.

The scripts set these by default. Verify on a fresh box:

```bash
ls -l /etc/wireguard/
stat -c '%a %n' /etc/wireguard/server_private.key /etc/wireguard/wg0.conf
```

### Disable password auth

```bash
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh
```

### Keep the box up to date

```bash
sudo apt-get update && sudo apt-get -y upgrade
```

A weekly cron is enough for this kind of VM.

### Rotate occasionally

- Generate a fresh server key every few months and reissue clients.
- If a device is lost or compromised, run `revoke-client.sh` for that
  peer immediately. The `clients/revoked/` archive keeps a copy for audit
  but no live peer references it.

### Don't run anything else on this VM

Resist the urge to install a web dashboard, a metrics exporter that talks
to a public endpoint, etc. Every additional service widens the attack
surface and uses bandwidth you need for the actual tunnel.

---

## 4. If something went wrong

- See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for connection issues.
- For suspected compromise, rotate keys first, investigate second.
- For ToS-related bans, see the ethics section above — there is no
  technical fix for those.