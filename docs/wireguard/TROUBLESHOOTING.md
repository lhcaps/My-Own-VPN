# WireGuard on Oracle Cloud — Troubleshooting

> Each section is **Symptom → Diagnose → Fix**. Start at the top, work
> down. All commands assume you are logged in as `ubuntu` and have
> `sudo -i`'d.

---

## 0. Rule out Oracle first

Many "VPN" issues are actually **OCI Security List / iptables** issues.

```bash
sudo iptables -L INPUT -n --line-numbers | head -40
sudo ss -lun 'sport = :51820' | head
ip route get 1.1.1.1
```

- If `ss` shows nothing on UDP 51820, the daemon isn't running.
- If `iptables` shows a `REJECT all` policy, add:

  ```bash
  sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT
  sudo netfilter-persistent save
  ```

---

## 1. "No handshake" on the client

### Symptom
`wg show wg0` on the server never shows a `latest handshake` for the
peer.

### Diagnose
1. **Server side:** is the daemon up?

   ```bash
   systemctl status wg-quick@wg0 --no-pager
   sudo ss -lun 'sport = :51820'
   ```
2. **Oracle Security List:** is UDP/51820 open? See
   [`ORACLE_FREE_TIER_SETUP.md`](ORACLE_FREE_TIER_SETUP.md) §5.
3. **Route to the public IP, no VPN involved:**

   ```bash
   # From your laptop
   nc -uvz <server-public-ip> 51820
   ```

   Should print something like `succeeded`. If `timed out` → Oracle or
   routing is blocking UDP/51820.
4. **Server iptables:** see §0.

### Fix

- If daemon is down: `sudo systemctl restart wg-quick@wg0`.
- If port is filtered by Oracle Security List: add the UDP/51820
  ingress rule and wait ~10 s.
- If `iptables` is blocking:
  `iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT`.

---

## 2. Handshake established but no internet

### Symptom
`wg show wg0` on the server shows a handshake and active peers; the
client cannot reach `1.1.1.1`, `8.8.8.8`, or any public IP.

### Diagnose

```bash
sudo iptables -t nat -L POSTROUTING -n -v
grep -A1 "PostUp\|PostDown" /etc/wireguard/wg0.conf
sudo sysctl net.ipv4.ip_forward
ip route get 1.1.1.1
```

### Fix (in order of likelihood)

1. **IP forwarding is off** (rare — install script enables it):

   ```bash
   echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
   sudo sysctl -p /etc/sysctl.d/99-wireguard.conf
   ```
2. **Wrong WAN interface in `PostUp`.** Oracle often pairs multiple
   NICs. The install script detects the WAN, but if you've added or
   changed routing since, the `iptables -o ethX` rule is wrong.
   Recreate with the current WAN:

   ```bash
   WAN="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
   sudo sed -i.bak "s/-o [^ ]*/-o ${WAN}/" /etc/wireguard/wg0.conf
   sudo systemctl restart wg-quick@wg0
   ```
3. **Oracle iptables shipped block list.** Some Oracle Ubuntu images
   install `iptables-persistent` and load a `REJECT all` policy. See
   §0.
4. **Egress IP denied.** If Oracle has marked your account as
   violating policy, **egress** may be rate-limited or blocked.
   Verify:

   ```bash
   curl -4 https://ifconfig.io
   ```

---

## 3. Wrong WAN interface detected

### Symptom
The `iptables MASQUERADE` rule targets `eth0` but real egress is
`enp0s3` (or vice versa). Common after a shape change.

### Diagnose

```bash
ip -o link show | awk -F': ' '{print $2}'
ip route get 1.1.1.1
```

### Fix
Re-run the detection by hand and update `wg0.conf`:

```bash
WAN="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
sudo sed -i "s/-o [a-zA-Z0-9._-]\+/-o ${WAN}/" /etc/wireguard/wg0.conf
sudo wg syncconf wg0 <(wg-quick strip wg0); wait $!
```

If you suspect the interface flipped after reboot, automate it:

```bash
sudo tee /etc/wireguard/postup.d/wan-detect.sh <<'EOF' >/dev/null
#!/bin/bash
WAN="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${WAN}" -j MASQUERADE
EOF
sudo chmod +x /etc/wireguard/postup.d/wan-detect.sh
```

(This is beyond the script defaults — only add it if you've actually
seen the interface flip.)

---

## 4. UDP/51820 not open in Oracle Security List

### Symptom
External `nc -uvz` times out. Server `ss` shows UDP/51820 listening.
Handshake never occurs.

### Fix
1. OCI Console → Networking → your VCN → Subnet → Default Security
   List.
2. Edit Ingress Rules; ensure:
   - **Protocol:** UDP
   - **Destination Port:** 51820
   - **Source CIDR:** `0.0.0.0/0` (or your IP)
3. Save.
4. Wait **5–30 seconds** for OCI to propagate. Re-test with `nc -uvz`.
5. If you also have an **NSG** on the instance, add UDP/51820 there
   too.

> Double-check: many people forget that Oracle provides *two* layers
> (Security List + Network Security Group). Both apply.

---

## 5. UFW conflict

### Symptom
`ufw status` shows rules that block UDP/51820 even though OCI is open.

### Diagnose

```bash
sudo ufw status verbose
```

### Fix
Disable UFW (Oracle iptables is what's authoritative on Always Free
images):

```bash
sudo ufw disable
sudo ufw reset
sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT
sudo netfilter-persistent save
```

If you insist on keeping UFW, set the default to allow + open 51820:

```bash
sudo ufw default allow incoming
sudo ufw allow 51820/udp comment "WireGuard"
sudo ufw allow OpenSSH
sudo ufw enable
```

---

## 6. iptables / nftables mixed

### Symptom
Commands to `iptables` don't seem to take effect — or `iptables`
errors with "iptables-legacy" / "iptables-nft" mismatch.

### Diagnose

```bash
sudo update-alternatives --query iptables
sudo iptables -V
sudo nft list ruleset | head
```

On Ubuntu 22.04+ the default is `iptables-nft`. The install script
uses `iptables` and that resolves to whichever the system has.

### Fix
Make sure your rule shows in **both**:

```bash
sudo iptables -t nat -L POSTROUTING -n -v | grep 10.8.0
```

If empty, reload PostUp manually:

```bash
WAN="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
sudo iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${WAN}" -j MASQUERADE
```

If you accidentally ended up with two iptables implementations, pick
one and stick with it:

```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-nft
# or /usr/sbin/iptables-legacy — match what `iptables -V` reports
```

---

## 7. MTU issue — games disconnect every minute

### Symptom
Tunnel connects, basic browsing works for a minute or two, then `wg
show` on the server counts RX/TX without errors, but the client gets
"destination host unreachable" or pages stop loading.

### Diagnose
Classic broken MTU. Try a smaller one.

### Fix
On the **client** config:

```ini
[Interface]
MTU = 1280
```

If 1280 works but 1380 doesn't, your ISP path silently fragments and
discards — keep MTU=1280. See
[`GAMING_TUNING.md`](GAMING_TUNING.md) §3 for tests.

---

## 8. Oracle "Out of host capacity"

### Symptom
`Instances → Create` fails with:

> Out of host capacity for shape VM.Standard.E2.1.Micro in
> availability domain ...

### Fix
1. Try a different region in
   [`ORACLE_FREE_TIER_SETUP.md`](ORACLE_FREE_TIER_SETUP.md) §1.
2. Try the **VM.Standard.A1.Flex** (Ampere ARM) with 1 OCPU + 6 GB RAM
   (or the half-split, 1 OCPU + 1 GB). Free tier allows you to use a
   single pool of ARM resources across multiple free instances.
3. Try again later. Capacity opens up.
4. **Do not** migrate to a paid shape to "get the same region" —
   you'll start getting billed. Cancel the instance immediately if
   you do.

---

## 9. Free tier idle / reclamation

### Symptom
The VM is up and reachable for a while, then disappears. Rebooting
the instance creates a new **public IP** you didn't pick.

### Cause
Oracle may reclaim an Always Free compute instance when **all** of
the following hold over a **continuous 7-day** window:

- CPU utilization, 95th percentile, below **20%**.
- Network utilization below **20%**.
- Memory utilization below **20%** (applies to **A1 shapes**).

When reclaimed, the compute is removed (boot volume is usually kept).
The public IP is gone; resources are returned to the pool.

### Fix
- See [`GAMING_TUNING.md`](GAMING_TUNING.md) §9 — keep the VM warm
  with a light cron, or actually use it.
- If you've already been reclaimed, recreate via the **same** OCI UI
  flow. The new instance will have a new public IP; update your
  client configs.

---

## 10. "I lost my private key" recovery

There is no recovery. That's by design. Generate a new peer with
`add-client.sh`, copy the new `.conf` to your device, then
`revoke-client.sh` the old one.

---

## 11. Logs

```bash
journalctl -u wg-quick@wg0 --no-pager -n 100
journalctl -k --no-pager | grep -E "wireguard|udp" | tail
```

Handy if the daemon crashes at boot — usually a malformed `wg0.conf`.

---

## 12. Emergency revert

If something goes wrong and you just want the tunnel *off*:

```bash
sudo systemctl stop wg-quick@wg0
sudo iptables -t nat -F POSTROUTING   # remove all NAT rules (only affects tunnel)
```

That does **not** touch your instance's SSH or other traffic.