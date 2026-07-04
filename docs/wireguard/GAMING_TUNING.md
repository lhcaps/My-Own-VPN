# Gaming Tuning & Latency Reality-Check

You're tunneling your game traffic through a free Oracle VM. That's a great
way to learn what real game networking looks like, and a bad way to
chase the lowest absolute ping. Read this before you start chasing numbers.

---

## 1. What you actually need to look at

Low ping matters but **stable ping matters more**. Most "lag complaints" in
shooter/RTS/MOBA games are actually:

| Symptom                  | Usually means                             |
|--------------------------|-------------------------------------------|
| Spikes every few seconds | jitter — packet transit time is varying   |
| Spikes at random moments | packet loss — packets are being dropped   |
| Skill shot goes elsewhere| desync — your client + server disagreed   |
| Steady "10 ms" higher    | ping — fine, learn to play with it        |

So your decision knob is **variance**, not absolute ping.

---

## 2. What affects variance through a VPN

In rough order of impact:

1. **Distance and route to the game server.** A blanket VPN doesn't move you
   "closer" to a game server. If the Oracle region is 30 ms from the game
   server and your ISP is 8 ms, the VPN can only add latency — never remove
   geographic distance.
2. **Oracle peering to the game's network.** If Oracle peers poorly with the
   game's CDN, you'll see spikes regardless of your local connection.
3. **The path inside Oracle (egress).** The `MASQUERADE` rule NATs your
   traffic through the VM's WAN. If that WAN NIC or its routing shifts,
   you'll see jitter.
4. **MTU.** Too small = lots of fragmentation overhead. Too large =
   fragmentation in flight, silent drops that look like packet loss.
5. **CPU on the VM.** WireGuard is fast (~1 Gbps on a modern OCPU), but the
   free tier has 1/8 OCPU. A free tier VM can saturate on bursts and back
   up; this surfaces as spikes.
6. **Your own upload.** WireGuard adds ~32 B per packet and AES-GCM overhead
   small but real. If your home upload is the bottleneck, tunneling makes
   things worse.

---

## 3. Test MTU: 1380, 1280, 1420

You should never set MTU by guessing. Find the largest size that doesn't
fragment.

### 3a. Quick and dirty

From the **client** (outside the VPN tunnel), ping the server with
`don't-fragment`:

```bash
# No-VPN baseline (ICMP with DF set)
ping -M do -c 5 -s 1380 <vpn-server-public-ip>
ping -M do -c 5 -s 1280 <vpn-server-public-ip>
ping -M do -c 5 -s 1420 <vpn-server-public-ip>
```

Watch for "message requires fragmentation and was sent DF". The largest
`ping -s` that **doesn't** get fragmented is your effective ceiling.

### 3b. Through the tunnel

After MTU=1380 is configured, retest using a TCP test through the tunnel —
**do not** rely on plain ICMP:

```bash
# Through the tunnel, use TCP, not ICMP
curl -sI https://www.cloudflare.com/cdn-cgi/trace   # works in any state
ping -M do -c 5 -s 1380 10.8.0.1                    # only meaningful inside tunnel
```

If `1380` causes issues but `1280` does, drop the client MTU to `1280`
(safest floor, matches the IPSec / Cloudflare minimum). If `1420` works
**and** ICMP to `1.1.1.1` through the tunnel also doesn't fragment, you can
bump to `1420` for ~3% efficiency.

**Note:** `set -euo pipefail` and happy-eyeballs routing differ per OS,
so test 3–5 times across a few minutes before deciding.

---

## 4. No-VPN vs VPN route comparison

Don't tunnel blindly. Compare with and without.

```bash
# Find a known target of the game server's CDN or IP
GameIP="<public ip of your game server>"

# No-VPN:
traceroute "${GameIP}"            # Linux
tracert   "${GameIP}"             # Windows / macOS

# With VPN, on a client behind the tunnel:
traceroute "${GameIP}"
```

You should see:

- **No VPN:** a path through your ISP, ~N hops, ending in the game's PoP.
- **With VPN:** add the Oracle VM **as a hop**, exit the same datacenter the
  game may live in.

If the Oracle egress ends on a *different* continent from the game server,
your VPN is making latency worse. Disconnect it for that game.

---

## 5. How to measure *stable* ping, not low ping

A single ping is noise. Use a *trend*:

```bash
# Linux / macOS
ping -c 600 -i 0.2 <game-server> > no-vpn.log
ping -c 600 -i 0.2 <game-server> > vpn.log

# Summary
awk '{print $7}' no-vpn.log | sort -n | awk '
  BEGIN{c=0}
  {a[c++]=$1}
  END{
    print "min  =", a[0]
    print "med  =", a[int(c/2)]
    print "p95  =", a[int(c*0.95)]
    print "p99  =", a[int(c*0.99)]
    print "max  =", a[c-1]
  }'

# Repeat on the other file.
```

What you actually compare is **p95 and p99**, not the average. A no-VPN
route with 25 ms average / 80 ms p99 almost always beats a VPN route with
5 ms average / 120 ms p99.

---

## 6. Game-blocked cloud IPs (be honest about this)

A fraction of competitive games **blacklist data-center IP ranges** (Oracle
is one of those ranges — the entire Oracle Cloud block is well-known). For:

- Casual coop / single-player journeys: usually fine.
- Competitive ladders: you may get bounced, get a hardware ban, or have
  matches silently de-ranked.

If a game says "we do not allow VPN connections", that's the game's policy.
Tunneling around it violates the TOS. **Don't do it.**

---

## 7. Use cases that *are* reasonable

- Personal privacy on hotel/airport Wi-Fi for general browsing.
- Routing traffic through a region for general web access.
- Locking down telemetry on devices where the OS allows you to require a
  specific tunnel.

If a use case is "I need to appear in another region to bypass this
service's geo-blocking", that is *almost never* a legitimate reason, even
when you can technically do it.

---

## 8. Ethics — read this

Don't use this stack to:

- **Evade region locks** for paid content (Steam, Netflix, etc.).
- **Defeat age verification** for adult services or restricted content.
- **Hide a banned account** to keep playing a game.
- **Bypass anti-cheat** detection.
- **Buy limited drops** via spoofed regions.

The VPN will not anonymize you from Oracle or law enforcement if subpoenaed,
and **wireguard logs are zero** by default — but every game can see you
are connecting from a cloud IP and act on it. A ban for TOS evasion is
permanent. Don't do that.

For legitimate uses: keep it boring, keep it legal, keep it small.

---

## 9. Keep the VM warm — Oracle "Always Free" isn't forever idle

Oracle has progressively tightened its reclamation rule: if your
**VM.Standard.A1.Flex** or **E2.1.Micro** shows CPU average under ~10% and
network under ~10% of capacity over rolling 7-day windows, the VM is
eligible for reclamation (the exact threshold varies and changes more
often than the docs do). Lost VMs are not recreatable into the same shape
in the same region — you may lose the public IP.

Two practical countermeasures, pick at least one:

### 9a. Light keepalive (cron)

```cron
*/3 * * * *    /usr/bin/nping --udp --dest-ip 1.1.1.1 --count 2 --quiet || true
```

`nping` is in the `nmap` package. Use it lightly — sending lots of packets
won't save you and uses your egress quota. Aim for <1 KB/min.

### 9b. A real-but-modest workload

If you actually use the VPN even a few hours a week for browsing / mobile
data, you're already above the threshold. For the rest of the time, a
cron job that triggers `wg-quick sync` every few hours is enough.

What **doesn't** help:

- Heavy CPU loads (only get you billed, on paid shapes).
- Rebooting — that creates a new ID and may make it worse.
- "Pings" that pretend to be game traffic — Oracle can correlate.

---

## 10. Summary checklist

Before complaining that "the VPN makes gaming worse":

- [ ] Measure **p95/p99** for 10+ minutes both ways.
- [ ] Confirm Oracle region is actually closer (or equal) to the game server.
- [ ] MTU is set to 1380 (or 1280 if your ISP is hostile to fragmentation).
- [ ] Client shows handshake < 120 s old (`sudo bash show-status.sh`).
- [ ] No other flow on the tunnel (file download, sync) competing for upload.
- [ ] VM has been "warm" (CPU/network ≥ a few %) for the past 24 hours.
