# PiRelay — Raspberry Pi 4 Reticulum / LoRa Mesh Relay

> A minimal, reproducible Ansible-driven build for a Raspberry Pi 4 serving as a
> Reticulum / LoRa mesh node (Waveshare SX1262 868M HAT) and lightweight network
> server (Git, file sharing, web dashboard).

> ⚠️ **Doc drift notice.** The architecture was simplified to **SX1262 only**.
> Sections below that reference LoRaWAN, the WM1302 HAT, ChirpStack, hat
> auto-detection (`pirelay-detect-hat`), `switch-profile.sh`, `lorawan-gateway.target`,
> or stacked/dual-hat setups are **out of date** and no longer reflect the
> playbook. The source of truth is [CLAUDE.md](CLAUDE.md), [playbooks/site.yml](playbooks/site.yml),
> and [group_vars/all.yml](group_vars/all.yml). This README will be rewritten in
> a later pass; for now, trust the code.

---

## 1. Hardware Bill of Materials

| Component | Role | Interface | Notes |
|---|---|---|---|
| Raspberry Pi 4 (4 GB+) | Host | — | 64-bit, Bookworm |
| Seeed WM1302 RPi Hat | LoRaWAN concentrator (8-ch) | SPI0 CE0, GPIO 17 reset | EU868 variant |
| Waveshare SX1262 868M LoRa Hat | Point-to-point LoRa / RNode | SPI0 CE1, GPIO 22/27 | Conflicts with WM1302 on some GPIO; see §3 |
| Seeed Wio-WM6108 | Wi-Fi HaLow (802.11ah) | USB (CDC-ECM/RNDIS) | Sub-GHz Wi-Fi, long range |
| MicroSD 32 GB+ (A2 class) | Boot/root | — | Consider USB SSD for longevity |
| PoE+ Hat _or_ 5 V / 3 A PSU | Power | — | PoE simplifies field deployment |
| 2×20 GPIO stacker header | Hat stacking | — | Solder onto WM1302 hat to pass through pins to SX1262 |

### 1.1 Single Hat, Auto-Detected at Boot

Only one LoRa HAT is connected at a time. To swap roles, power off the Pi,
physically change the HAT, and power on again — a systemd oneshot probes
the hardware at boot and activates the matching services.

#### Pin Allocation

| Signal | WM1302 HAT | SX1262 LoRa HAT |
|---|---|---|
| SPI0 MOSI | GPIO 10 | GPIO 10 |
| SPI0 MISO | GPIO 9 | GPIO 9 |
| SPI0 SCLK | GPIO 11 | GPIO 11 |
| Chip Select | CE0 (GPIO 8) | CE1 (GPIO 7) |
| Reset | GPIO 17 | GPIO 22 |
| BUSY | — | GPIO 27 |
| DIO1 | — | GPIO 4 |

> **Note — Waveshare SX1262 HAT:** confirm the jumper that selects CE0 vs
> CE1. Our setup uses CE1; set the jumper (or solder bridge) accordingly.

#### How detection works

`pirelay-detect-hat.service` runs at boot, before any radio target. The
Python probe in `/usr/local/bin/pirelay-detect-hat` performs two tests:

1. **SX1262 test (GPIO 27 pull-up).** Release GPIO 22 (reset). Configure
   GPIO 27 (BUSY) as input with the internal pull-up enabled. A real
   SX1262 in standby actively drives BUSY low → reads `LOW`. A floating
   (absent) pin → reads `HIGH`. Five samples are taken to defeat noise.
2. **WM1302 test (SPI version read).** Pulse GPIO 17 to reset the SX1302,
   then read the version register at 0x5600 on `spidev0.0`. A real chip
   responds with a non-trivial byte; an empty bus returns 0x00 or 0xFF.

```
                         pirelay-detect-hat.service
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
              probe SX1262                    probe WM1302
            (GPIO 27 pull-up)              (SPI 0x5600 read)
                    │                               │
                  found?                          found?
                    │                               │
           yes ◄────┴────► no               yes ◄──┴──► no
            │                                 │         │
            ▼                                 ▼         ▼
     systemctl start              systemctl start    profile = none
     lora-mesh.target              lorawan-gateway.target
```

The result is written to `/run/pirelay/radio-profile` and the corresponding
systemd target is activated. Neither target is `enabled` on boot — the
detection service is the single source of truth for what starts.

#### Ansible variables

```yaml
# Auto-detect at boot (default). Swap hats by power-cycling.
radio_detection_mode: auto
radio_profile_fallback: none   # when no hat is detected

# Or force a profile (skip hardware probing):
# radio_detection_mode: manual
# radio_profile_manual: lora-mesh
```

#### Manual override

The `switch-profile.sh` helper lets you override the detection result
without rebooting — useful for testing:

```bash
sudo /usr/local/bin/switch-profile.sh lora-mesh         # force Reticulum
sudo /usr/local/bin/switch-profile.sh lorawan-gateway   # force ChirpStack
sudo /usr/local/bin/switch-profile.sh detect            # re-run probe
sudo /usr/local/bin/switch-profile.sh status            # show state
sudo /usr/local/bin/switch-profile.sh both-off          # stop everything
```

Note: starting a radio target without the matching HAT physically present
will cause the service to fail at runtime (ChirpStack can't find the SX1302,
RNode can't open the serial device). Use `detect` or power-cycle after
swapping hardware.

---

## 2. Software Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Cockpit (9090)                    │
│              Web management dashboard               │
├────────┬────────┬───────────┬────────┬───────────────┤
│ Gitea  │ Samba  │ ChirpStack│Reticu- │ Wi-Fi HaLow   │
│ (3000) │(445/139│ (8080)    │lum/LXMF│ wm6108 iface  │
│        │  NFS)  │           │(4242)  │               │
├────────┴────────┴───────────┴────────┴───────────────┤
│           Nginx reverse proxy (80/443)               │
├──────────────────────────────────────────────────────┤
│  systemd targets: lorawan-gateway / lora-mesh        │
├──────────────────────────────────────────────────────┤
│      Raspberry Pi OS Lite (Bookworm, arm64)          │
└──────────────────────────────────────────────────────┘
```

### 2.1 Component Inventory

| Layer | Component | Why this one |
|---|---|---|
| OS | Raspberry Pi OS Lite Bookworm 64-bit | Broadest RPi driver support, minimal footprint |
| Web mgmt | Cockpit | Real Linux admin UI, zero-config systemd/journal/network integration |
| Reverse proxy | Nginx | Lightweight; terminates TLS, proxies Gitea + Cockpit + ChirpStack |
| Git server | Gitea | Full-featured, single binary, low RAM (~60 MB) |
| File sharing | Samba + optional NFS | Windows + macOS + Linux clients covered |
| LoRaWAN | ChirpStack (concentratord + gateway-bridge) | Open-source, EU868 OTAA/ABP, web UI |
| LoRa P2P / Mesh | Reticulum + rnodeconf (RNode firmware on SX1262) | Encrypted mesh, works over LoRa, TCP, I2P, serial |
| Messaging | LXMF / NomadNet | Delay-tolerant messaging over Reticulum |
| Wi-Fi HaLow | wpa_supplicant / hostapd for wm6108 | Driver support TBD — Seeed provides patched kernel module |
| Firewall | nftables (via Cockpit) | Default-deny, selective port opens |
| Monitoring | Cockpit + optional Prometheus node_exporter | Visible in Cockpit; Prometheus only if needed |
| Provisioning | Ansible | Idempotent, version-controlled, runs from any workstation |

---

## 3. Network Topology

```
Internet ←→ [Router/NAT] ←→ eth0 (192.168.x.x)
                                  │
                          ┌───────┴────────┐
                          │   Pi Relay      │
                          │                 │
                          │  wlan0 (onboard)│←→ local WiFi (mgmt fallback)
                          │  halow0 (wm6108)│←→ HaLow AP or client
                          │  lora0 (virtual)│←→ LoRa radio
                          └─────────────────┘
```

### 3.1 Port Map

| Port | Service | Exposure |
|---|---|---|
| 22 | SSH | LAN only (key-auth) |
| 80/443 | Nginx (proxy) | LAN; optionally NAT'd for internet |
| 3000 | Gitea (behind Nginx) | LAN |
| 8080 | ChirpStack web (behind Nginx) | LAN |
| 9090 | Cockpit (behind Nginx) | LAN |
| 445/139 | Samba | LAN only |
| 4242 | Reticulum shared instance | LAN / HaLow |

---

## 4. Ansible Playbook Structure

```
pirelay/
├── README.md              ← this file
├── inventory/
│   └── hosts.yml          ← Pi IP/hostname, SSH user
├── group_vars/
│   └── all.yml            ← tunables (domain, ports, dual_lora_mode, etc.)
├── roles/
│   ├── base/              ← OS hardening, packages, locale, timezone
│   ├── networking/        ← static IP, nftables, Wi-Fi HaLow driver
│   ├── nginx/             ← reverse proxy + self-signed TLS
│   ├── cockpit/           ← install + Nginx integration
│   ├── gitea/             ← binary install, SQLite, systemd unit
│   ├── samba/             ← shares config, users
│   ├── lorawan/           ← WM1302 + ChirpStack (concentratord + gw bridge)
│   ├── lora_mesh/         ← SX1262 reset + RNode flash + lora-mesh.target
│   ├── reticulum/         ← Reticulum shared instance, LXMF propagation
│   ├── radio_detect/      ← auto-detect which HAT is plugged in at boot
│   ├── halow/             ← WM6108 kernel module, wpa_supplicant/hostapd
│   └── monitoring/        ← node_exporter (optional)
├── playbooks/
│   ├── site.yml           ← full deployment
│   ├── radio-lorawan.yml  ← activate LoRaWAN profile only
│   └── radio-mesh.yml     ← activate LoRa mesh profile only
├── files/
│   ├── nftables.conf
│   ├── reticulum.conf     ← Reticulum config template
│   └── chirpstack/        ← ChirpStack region + gateway configs
├── templates/
│   ├── nginx-sites/       ← Jinja2 vhost templates
│   ├── gitea-app.ini.j2
│   └── smb.conf.j2
└── scripts/
    ├── flash-rnode.sh      ← flash SX1262 with RNode firmware (one-time)
    └── switch-profile.sh   ← manual override for the auto-detection result
```

### 4.1 Key Ansible Variables (`group_vars/all.yml`)

```yaml
# --- Identity ---
hostname: pirelay
domain: pirelay.local          # mDNS
timezone: Europe/Madrid
locale: en_US.UTF-8

# --- Networking ---
eth0_static_ip: ""             # empty = DHCP
halow_mode: client             # "client" or "ap"
halow_ssid: ""
halow_psk: ""
open_to_internet: false        # if true, NAT ports 80/443

# --- Radio profiles (single hat, auto-detected) ---
radio_detection_mode: auto     # auto | manual
radio_profile_manual: none     # used when radio_detection_mode: manual
radio_profile_fallback: none   # used when auto-detection finds no hat

# --- LoRaWAN (WM1302 / ChirpStack) ---
lorawan_region: EU868
lorawan_gateway_id: ""         # auto-generated from MAC if empty
chirpstack_version: "4"

# --- Reticulum / LoRa mesh ---
rnode_port: /dev/ttyS0         # SX1262 serial
rnode_frequency: 868000000
rnode_bandwidth: 125000
rnode_spreading_factor: 7
rnode_coding_rate: 5
reticulum_enable_transport: true
reticulum_announce_interval: 360  # seconds
lxmf_enable: true
nomadnet_enable: false         # TUI client, optional

# --- Services ---
gitea_version: "1.22"
gitea_http_port: 3000
gitea_db: sqlite3              # minimal; postgres available
samba_shares:
  - name: shared
    path: /srv/shared
    writable: true
  - name: git-backup
    path: /srv/gitea-backup
    writable: false

# --- TLS ---
tls_mode: self-signed          # or "letsencrypt" if open_to_internet
letsencrypt_email: ""

# --- System ---
enable_monitoring: false
swap_size_mb: 512              # small swap for low-RAM safety
disable_services:              # strip bloat
  - bluetooth
  - avahi-daemon
  - triggerhappy
  - ModemManager
```

---

## 5. Role Details

### 5.1 `base`
- `apt update && apt upgrade`
- Install essentials: `git`, `curl`, `python3-pip`, `nftables`, `dnsutils`, `htop`, `tmux`
- Set hostname, timezone, locale
- Disable unnecessary services (Bluetooth, etc.)
- Configure swap
- SSH hardening: key-only auth, disable root login, fail2ban
- Enable SPI, I2C, serial via `raspi-config` noninteractive

### 5.2 `networking`
- Optional static IP on eth0
- nftables firewall with default-deny INPUT, allow established, allow LAN ports
- mDNS via systemd-resolved (no Avahi — lighter)
- If `open_to_internet: true`, open 80/443 and configure Nginx for public access

### 5.3 `nginx`
- Install from Debian repos
- Generate self-signed cert (or provision Let's Encrypt via certbot)
- Reverse proxy vhosts:
  - `/` → Cockpit (websocket upgrade)
  - `/gitea` → Gitea
  - `/chirpstack` → ChirpStack (only when lorawan profile active)
- Harden headers (HSTS, X-Frame, CSP)

### 5.4 `cockpit`
- `apt install cockpit cockpit-networkmanager cockpit-storaged`
- Bind to `127.0.0.1:9090` (Nginx fronts it)
- Enable cockpit.socket

### 5.5 `gitea`
- Download binary for arm64
- Create `git` system user
- SQLite database at `/var/lib/gitea/data/gitea.db`
- Systemd unit
- Scheduled backup task (`gitea dump` cron to `/srv/gitea-backup/`)

### 5.6 `samba`
- Install, configure shares from `samba_shares` variable
- Create samba users matching system users
- Disable NetBIOS if not needed

### 5.7 `lorawan`
- Install ChirpStack concentratord + gateway-bridge from ChirpStack APT repo (arm64 .deb, keyring in `/etc/apt/keyrings/`)
- Deploy concentratord TOML + EU868 channel plan + gateway-bridge config
- GPIO reset helper for the SX1302 chip
- Services bound to `lorawan-gateway.target` via systemd drop-ins; target is **not** auto-enabled on boot — it is started by `pirelay-detect-hat.service` only when a WM1302 is detected

### 5.8 `lora_mesh`
- Install `rnodeconf` via pip (`--break-system-packages`)
- SX1262 reset helper script + one-shot RNode flash helper
- `lora-mesh.target` systemd target; **not** auto-enabled on boot — started by `pirelay-detect-hat.service` when an SX1262 is detected

### 5.8.5 `radio_detect`
- Install `/usr/local/bin/pirelay-detect-hat` (Python probe)
- Deploy `pirelay-detect-hat.service` systemd oneshot, ordered `Before=` the radio targets and `After=network.target`
- At boot, probes GPIO 27 with internal pull-up (SX1262 BUSY test), falls back to an SPI version-register read on CE0 (WM1302), writes the result to `/run/pirelay/radio-profile`, and calls `systemctl start` on the matching target

### 5.9 `reticulum`
- `pip install rns lxmf nomadnet --break-system-packages`
- Shared instance config (`/etc/reticulum/config`)
- Interfaces:
  - `RNodeInterface` over serial to SX1262 (when lora-mesh profile active)
  - `TCPServerInterface` on port 4242 (LAN clients)
  - `AutoInterface` (local multicast discovery)
  - Optionally `I2PInterface` for anonymous internet transport
- Enable transport mode so Pi acts as a relay node
- LXMF propagation node (store-and-forward messaging)
- Systemd unit: `reticulum.service`

### 5.10 `halow`
- Build/install Seeed WM6108 kernel module (out-of-tree, version-locked to kernel)
- Configure interface `halow0` via wpa_supplicant (client) or hostapd (AP)
- This role is **experimental** — driver maturity for WM6108 on mainline kernels is limited; expect manual patching

### 5.11 `monitoring` (optional)
- `node_exporter` on localhost:9100
- Cockpit already provides basic metrics; this role is for Prometheus scraping from another host

---

## 6. Deployment Workflow — Step by Step

### 6.1 Prerequisites (your workstation)

You need a computer (Linux, macOS, or Windows with WSL) with:

- **Python 3.8+** and **pip**
- **Ansible 2.14+**
- **SSH client** with a key pair (ed25519 recommended)

```bash
# Install Ansible (and the posix collection for sysctl)
pip install ansible
ansible-galaxy collection install ansible.posix community.general

# Verify
ansible --version   # should show 2.14+
```

### 6.2 Flash the Raspberry Pi SD Card

1. Download **Raspberry Pi Imager** from https://www.raspberrypi.com/software/
2. Select **Raspberry Pi OS Lite (64-bit, Bookworm)**
3. Click the gear icon (⚙) for advanced settings:
   - **Set hostname:** `pirelay`
   - **Enable SSH:** select "Allow public-key authentication only"
   - **Set authorized key:** paste your public key (`~/.ssh/id_ed25519.pub`)
   - **Set username:** `pi`
   - **Set locale:** timezone `Europe/Madrid`, keyboard layout as needed
   - **Configure Wi-Fi** (optional — only if you need wireless for initial access)
4. Write to SD card, insert into Pi, boot

### 6.3 Find Your Pi on the Network

```bash
# Option 1: mDNS (if your network supports it)
ping pirelay.local

# Option 2: check your router's DHCP leases

# Option 3: nmap scan
nmap -sn 192.168.1.0/24
```

### 6.4 Test SSH Access

```bash
ssh pi@<PI_IP_ADDRESS>
# Should log in without a password prompt (key-based auth)
# Type 'exit' to return to your workstation
```

### 6.5 Clone This Repo and Configure

```bash
git clone <your-repo-url> pirelay
cd pirelay
```

**Edit the inventory** — set the Pi's IP address:

```bash
# inventory/hosts.yml
nano inventory/hosts.yml
```

Change `ansible_host: 192.168.1.100` to your Pi's actual IP.

**Review variables** — customize for your setup:

```bash
nano group_vars/all.yml
```

Key variables to review:
| Variable | Default | Change if... |
|---|---|---|
| `eth0_static_ip` | `""` (DHCP) | You want a fixed IP |
| `radio_detection_mode` | `auto` | Set to `manual` if you want to force a profile |
| `radio_profile_manual` | `none` | In manual mode, which target to start at boot |
| `lorawan_region` | `EU868` | You're outside Europe |
| `tls_mode` | `self-signed` | You have a domain + public IP |
| `gitea_version` | `1.22.6` | Newer version available |
| `samba_shares` | 2 shares | Add/remove shares |

### 6.6 Run the Playbook

```bash
# Dry run first (shows what would change, changes nothing)
ansible-playbook playbooks/site.yml --check --diff

# Full deployment (takes ~10-20 minutes on first run)
ansible-playbook playbooks/site.yml

# Deploy specific roles only
ansible-playbook playbooks/site.yml --tags base,networking
ansible-playbook playbooks/site.yml --tags gitea
ansible-playbook playbooks/site.yml --tags lorawan,lora_mesh,reticulum
```

The playbook will print a summary at the end with access URLs.

> **Important:** If the `base` role enables SPI/serial overlays for the first time,
> you must reboot the Pi before radio roles can work:
> ```bash
> ssh pi@pirelay.local 'sudo reboot'
> # Wait ~30 seconds, then re-run the playbook
> ansible-playbook playbooks/site.yml
> ```

### 6.7 Flash RNode Firmware (one-time, on the Pi)

After the first deployment with the SX1262 hat connected:

```bash
ssh pi@pirelay.local

# Ensure lora-mesh profile is active (SX1262 reset pin HIGH)
sudo /usr/local/bin/switch-profile.sh lora-mesh

# Flash RNode firmware onto the SX1262
sudo /usr/local/bin/flash-rnode.sh /dev/ttyS0

# Verify
rnodeconf /dev/ttyS0 --info
```

### 6.8 Post-Deploy Verification

| Check | Command (on Pi or from workstation) |
|---|---|
| SSH works | `ssh pi@pirelay.local` |
| Cockpit UI | Browse to `https://pirelay.local/` (accept self-signed cert) |
| Gitea UI | Browse to `https://pirelay.local/gitea/` |
| Firewall active | `ssh pi@pirelay.local 'sudo nft list ruleset'` |
| Reticulum running | `ssh pi@pirelay.local 'rnstatus'` |
| LoRaWAN gateway | `ssh pi@pirelay.local 'journalctl -u chirpstack-concentratord --no-pager -n 20'` |
| Radio profile | `ssh pi@pirelay.local 'systemctl is-active lora-mesh.target'` |
| Samba shares | From Windows: `\\pirelay.local\shared` / From Linux: `smbclient -L pirelay.local` |

### 6.9 Create Samba Users

Samba requires separate password management:

```bash
ssh pi@pirelay.local

# Create a system user (if not already existing)
sudo useradd -m myuser
sudo usermod -aG sambashare myuser

# Set Samba password
sudo smbpasswd -a myuser
```

### 6.10 Swap LoRa HATs

The normal workflow is:

1. `sudo poweroff` on the Pi
2. Physically unplug the current LoRa HAT
3. Plug in the other HAT
4. Power the Pi back on

On next boot, `pirelay-detect-hat.service` probes the hardware and
automatically activates `lora-mesh.target` (SX1262) or
`lorawan-gateway.target` (WM1302). You can confirm with:

```bash
ssh pi@pirelay.local 'cat /run/pirelay/radio-profile'
ssh pi@pirelay.local 'sudo /usr/local/bin/switch-profile.sh status'
ssh pi@pirelay.local 'journalctl -u pirelay-detect-hat -b'
```

If you need to force a specific profile without the matching HAT
(e.g. for config testing), use `switch-profile.sh`:

```bash
sudo /usr/local/bin/switch-profile.sh lora-mesh         # force Reticulum
sudo /usr/local/bin/switch-profile.sh lorawan-gateway   # force ChirpStack
sudo /usr/local/bin/switch-profile.sh detect            # re-run probe
sudo /usr/local/bin/switch-profile.sh both-off          # stop everything
sudo /usr/local/bin/switch-profile.sh status            # show state
```

Or from your workstation:

```bash
ansible-playbook playbooks/radio-mesh.yml
ansible-playbook playbooks/radio-lorawan.yml
```

### 6.11 Re-running / Updating

The playbook is idempotent — safe to re-run at any time:

```bash
# Apply all changes (second run should show 0 changed)
ansible-playbook playbooks/site.yml

# Update only Gitea
ansible-playbook playbooks/site.yml --tags gitea

# See what would change before applying
ansible-playbook playbooks/site.yml --check --diff
```

### 6.12 Troubleshooting

| Problem | Solution |
|---|---|
| `UNREACHABLE!` in Ansible | Check Pi IP in `inventory/hosts.yml`, verify SSH key |
| SPI devices not visible | Reboot Pi after first `base` role run |
| Detection picks wrong HAT | Check `journalctl -u pirelay-detect-hat -b` — verify GPIO 27 reads LOW with SX1262 installed; check that no external pull-up/down is fitted |
| Detection returns `none` | Confirm the HAT is seated, GPIO 27 / CE lines not in use by another service, and SPI is enabled in `/boot/firmware/config.txt` |
| ChirpStack won't start | Check `journalctl -u chirpstack-concentratord -f` — verify the WM1302 HAT is physically plugged in |
| Reticulum can't find RNode | Ensure firmware is flashed (`flash-rnode.sh`), check `ls /dev/ttyS0` |
| Wrong target auto-started | Force one with `sudo switch-profile.sh lora-mesh` or set `radio_detection_mode: manual` in `group_vars/all.yml` |
| Nginx 502 Bad Gateway | The upstream service isn't running — check with `systemctl status gitea` / `cockpit.socket` |
| Cockpit login fails | Cockpit uses PAM — log in with the Pi's system username/password |
| Self-signed cert warning | Expected — browser will warn, click "Advanced" → "Proceed" |

---

## 7. Spain / EU868 Regulatory Notes

- **Frequency:** 863–870 MHz ISM band, licence-free
- **Duty cycle:** 1% on most sub-bands (36 s per hour of TX). Sub-band g1 (869.4–869.65 MHz) allows 10% duty cycle at 500 mW ERP
- **Max ERP:** 25 mW (14 dBm) on most sub-bands; 500 mW on g1
- **LoRaWAN:** ChirpStack defaults comply with EU868 duty cycle
- **Reticulum/RNode:** configure `airtime_limit` in RNode to enforce duty cycle; default in rnodeconf is compliant
- **Wi-Fi HaLow (802.11ah):** operates on 863–868 MHz in EU; **check Spanish CNMC regulations** — 802.11ah is not yet universally approved in all EU member states. Use at your own risk for experimentation

---

## 8. Security Considerations

- SSH: key-only, fail2ban, no root login
- All web services behind Nginx with TLS (self-signed or Let's Encrypt)
- Cockpit restricted to LAN unless explicitly opened
- nftables default-deny on INPUT
- Gitea: disable registration after creating admin account
- Samba: LAN-only binding
- Reticulum: encrypted by design (Curve25519 + AES-256)
- Regular `apt` security updates via unattended-upgrades

---

## 9. Resource Budget (estimated idle)

| Service | RAM | CPU | Disk |
|---|---|---|---|
| OS + systemd | ~120 MB | — | ~1.5 GB |
| Cockpit | ~30 MB | negligible | 50 MB |
| Nginx | ~10 MB | negligible | 5 MB |
| Gitea | ~60 MB | negligible | 100 MB + repos |
| Samba | ~20 MB | negligible | 10 MB + shares |
| ChirpStack stack | ~80 MB | low | 150 MB |
| Reticulum + LXMF | ~40 MB | low | 20 MB |
| **Total** | **~360 MB** | — | **~1.8 GB + data** |

Leaves ample headroom on a 4 GB Pi. A 2 GB model would work but is tight if ChirpStack and Gitea run simultaneously.

---

## 10. TODO / Implementation Checklist

### Phase 1 — Foundation
- [ ] Flash RPi OS Lite Bookworm 64-bit, enable SSH
- [ ] Create Ansible repo scaffold (`inventory/`, `group_vars/`, `roles/`)
- [ ] Implement `base` role (packages, hardening, SPI/serial enable)
- [ ] Implement `networking` role (static IP, nftables, mDNS)
- [ ] Test: SSH in, firewall blocks unexpected ports

### Phase 2 — Core Services
- [ ] Implement `nginx` role (self-signed TLS, reverse proxy stubs)
- [ ] Implement `cockpit` role (install, bind localhost, Nginx proxy)
- [ ] Implement `gitea` role (binary install, systemd, backup cron)
- [ ] Implement `samba` role (shares, users)
- [ ] Test: browse to Cockpit and Gitea via `https://pirelay.local/`

### Phase 3 — LoRaWAN Gateway (WM1302)
- [ ] Plug WM1302 HAT onto the Pi (single HAT, no stacking)
- [ ] Verify CE0 SPI device visible: `ls /dev/spidev0.0`
- [ ] Implement `lorawan` role (ChirpStack concentratord + gateway-bridge)
- [ ] Create `lorawan-gateway.target` systemd target (not auto-enabled)
- [ ] Test: boot, detection should activate LoRaWAN, see gateway in ChirpStack web UI

### Phase 4 — LoRa Mesh / Reticulum (SX1262)
- [ ] Power off, swap in SX1262 HAT (confirm CE1 jumper), power on
- [ ] Verify CE1 SPI device visible: `ls /dev/spidev0.1`
- [ ] Flash RNode firmware with `rnodeconf --autoinstall` (script: `flash-rnode.sh`)
- [ ] Implement `reticulum` role (config, shared instance, transport node)
- [ ] Implement `lora_mesh` role (reset helper, flash helper, lora-mesh.target)
- [ ] Test: boot, detection should activate lora-mesh, Pi appears as Reticulum transport node

### Phase 4.5 — Hat auto-detection
- [ ] Implement `radio_detect` role with Python probe (`pirelay-detect-hat`)
- [ ] Verify `journalctl -u pirelay-detect-hat -b` shows correct detection for each HAT
- [ ] Verify `/run/pirelay/radio-profile` matches the plugged-in HAT
- [ ] Test: swap HAT, power-cycle, confirm clean transition to the other profile

### Phase 5 — Wi-Fi HaLow
- [ ] Obtain WM6108 kernel module source from Seeed
- [ ] Implement `halow` role (build module, configure interface)
- [ ] Test: ping Pi over HaLow link
- [ ] Document any kernel version pins or patches required

### Phase 6 — Hardening & Polish
- [ ] Enable unattended-upgrades
- [ ] Cockpit dashboard: verify network, storage, journal panels work
- [ ] Write `group_vars/all.yml` documentation / comments
- [ ] Add Ansible tags for selective runs (`--tags radio,gitea`)
- [ ] Create backup strategy (gitea dump + rsync Samba shares to off-site)
- [ ] Test full idempotent re-run (`site.yml` twice, no changes)

### Phase 7 — Optional Enhancements
- [ ] Let's Encrypt TLS (requires public domain + port 80 open)
- [ ] NomadNet TUI for Reticulum messaging
- [ ] I2P transport for anonymous Reticulum peering
- [ ] Prometheus + Grafana on a separate host, scraping node_exporter
- [ ] USB SSD boot for SD card longevity
- [ ] Refine detection heuristics (e.g. add retry logic for flaky SPI responses)

---

## 11. Useful Commands Reference

```bash
# Inspect / force radio profile
sudo /usr/local/bin/switch-profile.sh status
sudo /usr/local/bin/switch-profile.sh detect
sudo /usr/local/bin/switch-profile.sh lora-mesh
sudo /usr/local/bin/switch-profile.sh lorawan-gateway

# See detection result & logs
cat /run/pirelay/radio-profile
journalctl -u pirelay-detect-hat -b

# Check Reticulum status
rnstatus

# Check LoRaWAN gateway
journalctl -u chirpstack-concentratord -f

# Gitea admin
sudo -u git /usr/local/bin/gitea admin user create --admin ...

# Samba user
sudo smbpasswd -a myuser

# Re-run Ansible (from workstation)
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --diff
```

---

## 12. References

- [Reticulum Network Stack](https://reticulum.network/)
- [RNode / rnodeconf](https://github.com/markqvist/rnodeconf)
- [LXMF](https://github.com/markqvist/lxmf)
- [ChirpStack](https://www.chirpstack.io/docs/)
- [Seeed WM1302 wiki](https://wiki.seeedstudio.com/WM1302_module/)
- [Waveshare SX1262 LoRa Hat](https://www.waveshare.com/wiki/SX1262_868M_LoRa_HAT)
- [Seeed Wio-WM6108 (Wi-Fi HaLow)](https://wiki.seeedstudio.com/wio_wm6108/)
- [Cockpit Project](https://cockpit-project.org/)
- [Gitea](https://gitea.io/)

---

*Generated as a project blueprint. Implementation intended via Claude Code in a separate session.*