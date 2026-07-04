# Oracle Cloud Always Free — Setup

> Personal-use WireGuard tunnel on Oracle Cloud **Always Free**.
> Read [`SECURITY.md`](SECURITY.md) before you start.

---

## 0. What Always Free gives you (as of 2026)

Two **VM.Standard.E2.1.Micro** (x86) instances — 1/8 OCPU, 1 GB RAM each.
Or a single **VM.Standard.A1.Flex** (ARM Ampere) pool you can split up
to 4 OCPUs / 24 GB RAM across VMs. The ARM shape is often out of
capacity and frequently harder to provision; the E2.1.Micro is the safer
default.

---

## 1. Pick a region close to the games you play

Cloud-to-game-server distance matters more than a paper ping. Pick the
closest Oracle region that actually has Always Free capacity:

| Country / city     | Region identifier        |
|--------------------|--------------------------|
| Tokyo              | `ap-tokyo-1`             |
| Osaka              | `ap-osaka-1`             |
| Seoul              | `ap-seoul-1`             |
| Singapore          | `ap-singapore-1`         |
| Hong Kong          | `ap-hongkong-1`          |

Always Free shapes are **often out of capacity** in the smallest
regions. If your top pick is unavailable, try another on this list.
You can create the account in one region and create instances in
another, but **Always Free compute can only be created in your home
region**. Pick the home region carefully — it is fixed for the lifetime
of the account.

---

## 2. Create an Always Free account

1. Go to https://cloud.oracle.com/free/ and click **Start for Free**.
2. You need a credit card for a $0 hold; cancel any time within the
   30-day risk-free window.
3. Sign in to the OCI console. You will land in your **Home Region**.

> The home region is fixed forever. Pick it carefully (use the table
> above). You can still create paid resources in other regions later,
> but Always Free instances live in the home region.

---

## 3. Create a VCN (if the wizard didn't)

Networking → **Virtual Cloud Networks** → *Start VCN Wizard* →
`VCN with Internet Connectivity` → pick your region → create.

A default route table, internet gateway, and a default Security List
are created automatically. Don't skip the wizard — it removes many
surprises.

---

## 4. Launch the Always Free VM

Compute → **Instances** → *Create Instance*.

| Setting        | Pick this                                                          |
|----------------|--------------------------------------------------------------------|
| Name           | `wg-gaming-<region>`                                               |
| Placement      | Pick a region with free capacity from §1                           |
| Image          | **Canonical Ubuntu 22.04 LTS** `aarch64` (or `x86_64`) — minimum   |
| Shape          | `VM.Standard.E2.1.Micro` (or `VM.Standard.A1.Flex` w/ 1 OCPU)       |
| Networking     | The VCN from §3 (defaults: subnet, public IP)                      |
| SSH key        | Generate or upload                                                 |
| Boot volume    | Default size is fine                                               |

Make sure **Assign a public IPv4 address** is checked.

Click **Create**.

---

## 5. Open UDP/51820 in the Oracle Security List

The default Security List **blocks** everything except SSH (22). You
must open the WireGuard port explicitly.

1. Compute → Instances → your VM → VCN link.
2. Networking → the VCN → **Subnets** → the public subnet →
   **Default Security List**.
3. *Add Ingress Rule*:

```
Source CIDR        : 0.0.0.0/0   (tighten to your home IP after first connect)
Protocol           : UDP
Destination Port   : 51820
```

> **Do not** open TCP/51820. WireGuard is UDP-only.
>
> You can restrict the Source CIDR to your home IP (`/32`) for tighter
> scope. If you're on mobile or a variable IP, leave it 0.0.0.0/0.

Save and wait ~5 s for the rule to propagate.

> **Heads up:** many instances also have a **Network Security Group
> (NSG)** in addition to the Security List. Both layers apply. If you
> have an NSG attached to the VNIC, add the same UDP/51820 rule there.

---

## 6. Sanity-check before you script

SSH in:

```bash
ssh ubuntu@<public-ip>
```

Confirm:

```bash
sudo -i
ip -4 addr show scope global      # note: shows PRIVATE IP, not public
curl -4 ifconfig.io               # confirm outbound IPv4
```

> ⚠️  `ip addr` shows the VNIC's **private** IP, not the public one. The
> public IPv4 lives in the OCI Console and is attached at the cloud edge.
> The bootstrap script does **not** auto-detect the public IP; you must
> set `/etc/wireguard/server_endpoint` manually. See §10.

---

## 7. Run the bootstrap

```bash
sudo apt-get update -y && sudo apt-get install -y git
git clone https://github.com/lhcaps/My-Own-VPN.git
cd My-Own-VPN
chmod +x scripts/wireguard/*.sh
sudo bash scripts/wireguard/install-oracle-wireguard.sh
```

The script:

- Installs `wireguard`, `qrencode`, `iptables`, `iptables-persistent`.
- Enables `net.ipv4.ip_forward=1` via `/etc/sysctl.d/99-wireguard.conf`.
- Creates `/etc/wireguard/server_private.key` and `server_public.key`
  if absent (kept `chmod 600`).
- Writes `/etc/wireguard/wg0.conf` if absent — single `wg0` interface
  with NAT MASQUERADE through the detected WAN.
- Runs `systemctl enable --now wg-quick@wg0`.
- Prints a checklist reminding you to open **UDP/51820** in the
  Security List (you already did this in §5).

It will **not** print the server private key, and will **not** overwrite
existing keys or config.

---

## 8. Add your first client

```bash
sudo bash scripts/wireguard/add-client.sh my-laptop
```

You will get:

- a path to `/etc/wireguard/clients/my-laptop.conf`
- an ANSI QR code in the terminal

**Import on the device:**

| Platform  | How                                                                |
|-----------|--------------------------------------------------------------------|
| Windows   | Copy the `.conf` (e.g. `scp`) and open it in the WireGuard app → *Import tunnel(s) from file*. |
| macOS     | Open the WireGuard app, click `+` → *Import tunnel(s) from file*.  |
| iOS       | Install the app, tap `+` → *Create from QR code* — scan the QR.    |
| Android   | Same as iOS — install from Play Store, tap `+` → *Scan QR code*.   |
| Linux     | Drop the file under `/etc/wireguard/` and run `wg-quick up <name>`.|

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

## 10. Hardening

- Tighten the Security List to your home IP (`/32`) for UDP/51820 once
  you've confirmed things work.
- Set `MTU = 1380` on the client (the install script does this by
  default).
- Rotate every few months: rerun `install-oracle-wireguard.sh` to keep
  existing keys; or, to fully rotate, `mv /etc/wireguard/server_private.key{,.old}` and rerun.

---

## 11. Reclamation risk (read this)

Oracle may reclaim Always Free compute instances if **all** of the
following hold for a **continuous 7-day window**, per the official
[Always Free Resources](https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
documentation:

- CPU utilization, 95th percentile, below **20%**.
- Network utilization below **20%**.
- Memory utilization below **20%** (A1 shapes only).

When reclaimed, the compute is removed (boot volume is usually kept),
and you may not be able to recreate it in the same region/shape. See
[`GAMING_TUNING.md`](GAMING_TUNING.md) §"Keep the VM warm" for practical
countermeasures.

> Note: the exact thresholds have shifted over time (10% → 15% → 20% on
> different shape generations). Always cross-check the live Oracle docs
> link above before relying on a specific number.

---

## 12. Don't do this

- Don't paste Oracle tokens, API keys, or passwords into this repo.
- Don't use the tunnel to evade region locks, bans, or age checks.
  See [`SECURITY.md`](SECURITY.md).