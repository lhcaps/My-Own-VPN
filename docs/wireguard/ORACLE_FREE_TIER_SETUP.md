# Oracle Cloud Always Free + WireGuard — Setup

> Personal-use VPN tunnel on Oracle Cloud's **Always Free** tier.
> For low-stakes routing (incl. gaming). Read the ethics & risk notes at the
> bottom before you go further.

---

## 0. What you get (Always Free, as of 2026)

Two **VM.Standard.E2.1.Micro** instances (Ampere ARM) — 1/8 OCPU + 1 GB RAM each,
or x86 shapes in some regions. VM.Standard.A1.Flex lets you split your ARM
allowance (up to 4 OCPUs / 24 GB RAM total) across VMs.

Pick whichever is available in your home region. For most people the **VM.Standard.E2.1.Micro** is the safest bet — no shape-availability games.

---

## 1. Recommended regions (from VN / SEA)

Cloud-to-gamer distance matters more than paper ping. Pick the closest
Oracle region that **actually has** the Always Free shape in stock:

| Country | Region key (identifier)       | City           |
|---------|------------------------------|----------------|
| Japan   | `ap-tokyo-1`                 | Tokyo          |
| Japan   | `ap-osaka-1`                 | Osaka          |
| Korea   | `ap-seoul-1`                 | Seoul          |
| SG      | `ap-singapore-1`             | Singapore      |
| HK      | `ap-hongkong-1`              | Hong Kong      |

Always Free shapes are often **out of capacity** in the smallest regions.
If your top pick is "out of host capacity", try another region on this list.
Creating the account in `ap-tokyo-1` and then creating the instance in
`ap-singapore-1` is normal.

---

## 2. Create an Always Free account

1. Go to https://cloud.oracle.com/free/ and click **Start for Free**.
2. You will need a credit card for the $0 hold. Cancel anytime in 30 d risk-free.
3. Sign in to the OCI console. You'll land in your **Home Region**.

> The Home Region is fixed forever — choose it carefully (pick the closest one
> above). You **can** still create resources in other regions later.

---

## 3. Create a VCN (if the wizard didn't)

Networking → **Virtual Cloud Networks** → *Start VCN Wizard* →
`VCN with Internet Connectivity` → pick your region → create.

A default route table, an internet gateway, and a default Security List are
created automatically. Don't skip the wizard — it removes many surprises.

---

## 4. Launch the Always Free VM

Compute → **Instances** → *Create Instance*.

| Setting        | Pick this                                                       |
|----------------|------------------------------------------------------------------|
| Name           | `wg-gaming-<region>`                                            |
| Placement      | Pick a region with free capacity from §1                        |
| Image          | **Canonical Ubuntu 22.04 LTS** `aarch64` (or `x86_64`) — minimum |
| Shape          | `VM.Standard.E2.1.Micro` (or `VM.Standard.A1.Flex` w/ 1 OCPU)    |
| Networking     | Select the VCN from §3 (defaults: subnet, public IP)             |
| SSH key        | Generate or upload                                              |
| Boot volume    | Default size is fine                                            |

Make sure **Assign a public IPv4 address** is checked.

Click **Create**.

---

## 5. Open UDP/51820 in the Oracle Security List

By default the Security List **blocks** everything except SSH (22). You must
open the WireGuard port explicitly:

1. Compute → Instances → your VM → VCN link
2. Networking → the VCN → **Subnets** → the public subnet → **Default Security List**
3. *Add Ingress Rule*:

```
Source CIDR        : 0.0.0.0/0            (tighten to your home IP after first connect)
Protocol           : UDP
Destination Port   : 51820
```

> **Do not** open TCP/51820. WireGuard is UDP-only.
>
> You *can* restrict Source CIDR to your home IP (`/32`) for tighter scope.
> If you're on mobile / variable IP, leave it 0.0.0.0/0 behind a non-default
> security list that just exposes 22 + 51820.

Save and wait ~5 s for the rule to propagate.

---

## 6. Sanity-check before you script

SSH in:

```bash
ssh ubuntu@<public-ip>
```

Confirm:

```bash
sudo -i
ip -4 addr show scope global      # confirm public IPv4 attached
curl -4 ifconfig.io               # confirm outbound IPv4
```

---

## 7. Run the bootstrap

```bash
sudo apt-get update -y && sudo apt-get install -y git
git clone <your-repo-url> vpn-home
cd vpn-home
chmod +x scripts/wireguard/*.sh
sudo bash scripts/wireguard/install-oracle-wireguard.sh
```

The script will:

- install `wireguard`, `qrencode`, `iptables`, `iptables-persistent`
- enable `net.ipv4.ip_forward=1` via `/etc/sysctl.d/99-wireguard.conf`
- create `/etc/wireguard/server_private.key` and `server_public.key` if absent
- write `/etc/wireguard/wg0.conf` if absent (single `wg0` interface, NAT via the
  detected WAN)
- `systemctl enable --now wg-quick@wg0`
- print a checklist reminding you to open **UDP/51820** in the Security List
  (you already did this in §5)

It will **not** print the server private key, and will **not** overwrite
existing keys or config.

---

## 8. Add your first client

```bash
sudo bash scripts/wireguard/add-client.sh my-laptop
```

You'll get:

- a path to `/etc/wireguard/clients/my-laptop.conf`
- an ANSI QR code in the terminal

**Import on the device:**

- **WireGuard Windows:** copy the `.conf` file (e.g. via `scp`) and open it
  in the WireGuard app → *Import tunnel(s) from file*.
- **WireGuard Android/iOS:** install the app, tap "+", then *Scan QR code*.
- **WireGuard macOS / Linux:** drop the file under `/etc/wireguard/` and run
  `wg-quick up <name>`.

---

## 9. Verify

```bash
sudo bash scripts/wireguard/show-status.sh
```

On the client:

```bash
curl https://ifconfig.io       # should show Oracle's IP, not your ISP
```

---

## 10. Hardening (recommended)

- Replace `0.0.0.0/0` Source CIDR on the Security List with your home IP.
- Set `MTU = 1380` on the client (the install script does this by default).
- Rotate every few months: `install-oracle-wireguard.sh` keeps existing keys;
  rerun `add-client.sh` to issue new ones, then revoke old.
- Move the orphan revoked-client files out of `/etc/wireguard/clients/revoked/`
  to your backup of choice. Nothing about WireGuard on this disk is sensitive
  to the **public** — but private keys are private.

---

## Read this before you wrap up

- **Always Free capacity is fickle.** If the install fails with *Out of host
  capacity*, retry in a few hours, or change region. See `TROUBLESHOOTING.md`.
- **Idle reclaim.** Oracle reclaims VMs whose CPU average is below ~10% and
  network below 10% of capacity for **7 days** (and the rules tighten
  frequently). See `GAMING_TUNING.md` §"Keep the VM warm" — this is the
  single most common cause of "it just stopped working".
- **Ethics.** Do not use any VPN — Oracle or otherwise — to circumvent game
  region locks, evade age verification, hide ban evasion, or break another
  service's TOS. See `GAMING_TUNING.md` §Ethics.
