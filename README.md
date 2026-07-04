# My-Own-VPN

> Self-hosted WireGuard VPN on Oracle Cloud **Always Free**, for personal
> routing and legitimate gaming use. Not for ban-evasion, age-check bypass,
> or anything that violates a service's ToS.

This repository contains:

- Idempotent shell scripts to bootstrap a WireGuard server on Ubuntu
  22.04 / 24.04 and manage peers.
- A small set of docs covering Oracle Always Free, gaming routing, and
  troubleshooting.

It does **not** contain any private keys, client configs, Oracle
credentials, or API tokens. **Don't add any.**

---

## Quick start

You need a fresh Ubuntu 22.04 or 24.04 instance on Oracle Cloud Always Free
in a region close to your game server. See
[`docs/wireguard/ORACLE_FREE_TIER_SETUP.md`](docs/wireguard/ORACLE_FREE_TIER_SETUP.md)
for the full step-by-step.

```bash
# As root on the Oracle VM, after SSH and after opening UDP/51820 in
# the OCI Security List:

sudo apt-get update -y && sudo apt-get install -y git
git clone https://github.com/lhcaps/My-Own-VPN.git
cd My-Own-VPN
chmod +x scripts/wireguard/*.sh
sudo bash scripts/wireguard/install-oracle-wireguard.sh
sudo bash scripts/wireguard/add-client.sh my-laptop
sudo bash scripts/wireguard/show-status.sh
```

The `add-client.sh` script prints an ANSI QR code for mobile and writes a
`.conf` file you can import into the WireGuard app on Windows, macOS, iOS,
Android, or Linux.

---

## Repository layout

```
My-Own-VPN/
â”œâ”€â”€ scripts/wireguard/
â”‚   â”œâ”€â”€ install-oracle-wireguard.sh   # one-shot server bootstrap
â”‚   â”œâ”€â”€ add-client.sh                 # add a peer (no downtime)
â”‚   â”œâ”€â”€ revoke-client.sh              # remove a peer (no downtime)
â”‚   â””â”€â”€ show-status.sh                # operator view
â”œâ”€â”€ docs/wireguard/
â”‚   â”œâ”€â”€ ORACLE_FREE_TIER_SETUP.md
â”‚   â”œâ”€â”€ GAMING_TUNING.md
â”‚   â”œâ”€â”€ TROUBLESHOOTING.md
â”‚   â””â”€â”€ SECURITY.md
â”œâ”€â”€ .github/workflows/shellcheck.yml  # CI: shellcheck every script
â”œâ”€â”€ .gitignore
â”œâ”€â”€ LICENSE                           # MIT
â””â”€â”€ README.md
```

---

## How peer lifecycle works (no restarts)

`add-client.sh` and `revoke-client.sh` both use:

```bash
wg syncconf wg0 <(wg-quick strip wg0); wait $!
```

`wg-quick strip` flattens the human-friendly `wg0.conf` (with `PostUp`
and friends) into the form `wg(8)` consumes. `wg syncconf` then applies
**only the diff** to the running interface â€” existing peers keep their
handshakes, no one gets disconnected. The `wait $!` is required because
**bash does not propagate exit codes from process substitutions**, even
under `set -euo pipefail`. See [WireGuard commit `26683f6c`](https://git.zx2c4.com/wireguard-tools/commit/?h=v1.0.20200820&id=26683f6c9ad18d9914b23312c221f27fd5ecab51)
for the upstream rationale.

---

## Defaults

| Setting                | Value           |
|------------------------|-----------------|
| Listen port            | UDP 51820       |
| Server subnet          | 10.8.0.0/24     |
| Server IP              | 10.8.0.1/24     |
| Client DNS             | 1.1.1.1         |
| Client MTU             | 1380            |
| Client AllowedIPs      | 0.0.0.0/0       |
| PersistentKeepalive    | 25              |
| WAN interface detection | `ip route get 1.1.1.1 \| awk '{print $5; exit}'` |

To change the subnet, port, or endpoint IP, edit the constants at the top
of `install-oracle-wireguard.sh` and rerun it (the script is idempotent).

---

## Security

Read [`docs/wireguard/SECURITY.md`](docs/wireguard/SECURITY.md) before you
do anything else. In short:

- Never commit `*.key`, `*.conf`, or anything under `clients/`.
- Never paste Oracle tokens, API keys, or passwords into this repo.
- Don't use this stack to evade region locks, bans, age verification, or
  anti-cheat.

The `.gitignore` in this repo already excludes those paths. GitHub's
**secret-scanning** will reject some of them by default, but you should
not rely on that as a substitute for good hygiene.

---

## Continuous integration

Every push and pull request runs `shellcheck` against the four scripts in
`scripts/wireguard/`. See `.github/workflows/shellcheck.yml`.

---

## Limitations

- This targets Ubuntu 22.04 / 24.04 on `aarch64` or `x86_64`. Other
  distros will mostly work but are not tested.
- Oracle Cloud's Always Free reclamation rule: a VM may be reclaimed if
  **all** of the following hold for a continuous 7-day period: CPU
  P95 < 20%, network utilization < 20%, memory utilization < 20% (A1
  shapes). See [`docs/wireguard/GAMING_TUNING.md`](docs/wireguard/GAMING_TUNING.md)
  for how to keep the instance warm.
- You get at most a handful of Mbps and 1/8 OCPU on a free tier. This is
  fine for general browsing and many online games; it is not a CDN.

---

## License

MIT. See [`LICENSE`](LICENSE).