# PiRelay — Raspberry Pi 4 Communication Relay & Server

> A minimal, reproducible Ansible-driven build for a Raspberry Pi 4 serving as a
> multi-protocol radio relay (LoRa, LoRaWAN, Wi-Fi HaLow, Reticulum) and
> lightweight network server (Git, file sharing, web dashboard).

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

### 1.1 Stacked Hats — GPIO Pin Map & Software Switch

Both hats attach to SPI0 but use **different chip-selects and GPIO lines**, so
they can be physically stacked using a 2×20 GPIO stacker header and
software-switched without re-wiring.

#### Pin Allocation

| Signal | WM1302 Hat | SX1262 LoRa Hat | Conflict? |
|---|---|---|---|
| SPI0 MOSI | GPIO 10 | GPIO 10 | Shared bus ✓ |
| SPI0 MISO | GPIO 9 | GPIO 9 | Shared bus ✓ |
| SPI0 SCLK | GPIO 11 | GPIO 11 | Shared bus ✓ |
| **Chip Select** | **CE0 (GPIO 8)** | **CE1 (GPIO 7)** | **No conflict** |
| Reset | GPIO 17 | GPIO 22 | No conflict |
| Busy / DIO1 | — | GPIO 27 (BUSY), GPIO 4 (DIO1) | No conflict |
| Power enable | — | — | See note below |

> **Note — Waveshare SX1262 hat:** Confirm your specific revision's jumper
> settings. Some revisions default CE1 to GPIO 7, others use a solder bridge.
> Check the silk screen on the PCB and set to CE1 if not already.

#### Software Switch via GPIO Reset

The trick: **hold a hat's RESET pin LOW to electrically disable it on the SPI
bus.** Both device tree overlays stay loaded; the inactive hat simply doesn't
respond.

```
┌──────────────────────────────────────────────────────────┐
│                       SPI0 Bus                           │
│                                                          │
│   ┌─────────────┐  CE0    ┌──────────────┐  CE1         │
│   │   WM1302    │◄────────│    SX1262    │◄──────       │
│   │  (LoRaWAN)  │         │  (LoRa P2P)  │              │
│   └──────┬──────┘         └──────┬───────┘              │
│     RST=GPIO 17             RST=GPIO 22                  │
│          │                       │                       │
│     HIGH=active             HIGH=active                  │
│     LOW=disabled            LOW=disabled                 │
└──────────────────────────────────────────────────────────┘
```

The switch script (`scripts/switch-profile.sh`) does three things:

1. Stops the outgoing profile's services
2. Pulls the outgoing hat's RESET pin LOW (disable)
3. Pulls the incoming hat's RESET pin HIGH, starts its services

```bash
#!/usr/bin/env bash
# Usage: switch-profile.sh lorawan-gateway | lora-mesh | both-off

set -euo pipefail

WM1302_RST=17
SX1262_RST=22

gpio_set() { echo "$2" > /sys/class/gpio/gpio$1/value; }
gpio_export() {
  [ -d /sys/class/gpio/gpio$1 ] || echo "$1" > /sys/class/gpio/export
  echo "out" > /sys/class/gpio/gpio$1/direction
}

gpio_export $WM1302_RST
gpio_export $SX1262_RST

case "${1:-}" in
  lorawan-gateway)
    systemctl stop lora-mesh.target 2>/dev/null || true
    gpio_set $SX1262_RST 0   # disable SX1262
    gpio_set $WM1302_RST 1   # enable WM1302
    sleep 0.5
    systemctl start lorawan-gateway.target
    echo "Active profile: lorawan-gateway"
    ;;
  lora-mesh)
    systemctl stop lorawan-gateway.target 2>/dev/null || true
    gpio_set $WM1302_RST 0   # disable WM1302
    gpio_set $SX1262_RST 1   # enable SX1262
    sleep 0.5
    systemctl start lora-mesh.target
    echo "Active profile: lora-mesh"
    ;;
  both-off)
    systemctl stop lorawan-gateway.target 2>/dev/null || true
    systemctl stop lora-mesh.target 2>/dev/null || true
    gpio_set $WM1302_RST 0
    gpio_set $SX1262_RST 0
    echo "All radios disabled"
    ;;
  *)
    echo "Usage: $0 {lorawan-gateway|lora-mesh|both-off}" >&2
    exit 1
    ;;
esac
```

#### Ansible Variable

```yaml
# Stacked hat mode (both physically connected, software-switched)
stacked_hats: true              # enables both DT overlays at boot
default_radio_profile: lora-mesh  # which profile starts on boot
```

#### Simultaneous Operation (Experimental)

Since the hats occupy separate CE lines, it is **theoretically possible** to run
both stacks simultaneously (LoRaWAN gateway + Reticulum mesh). Both RESET pins
stay HIGH, and each service talks to its own CE line. The Ansible variable
`dual_radio_mode: false` gates this. Risks:

- SPI bus contention under heavy traffic (both hats share MOSI/MISO/SCLK)
- Potential RF interference at 868 MHz (antennas centimetres apart)
- Increased power draw (~0.5 W extra)

Recommendation: start with software-switching, test dual mode once single
profiles are stable.

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
│   ├── lorawan/           ← WM1302 SPI overlay, ChirpStack stack
│   ├── lora_mesh/         ← SX1262 overlay, RNode firmware, Reticulum config
│   ├── reticulum/         ← Reticulum shared instance, LXMF, NomadNet
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
    ├── flash-rnode.sh      ← flash SX1262 with RNode firmware
    └── switch-profile.sh   ← convenience wrapper around systemd targets
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

# --- Radio profiles (stacked hats) ---
stacked_hats: true             # both hats physically connected via stacker
dual_radio_mode: false         # true = both active simultaneously (experimental)
default_radio_profile: lora-mesh  # or lorawan-gateway

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
- Enable SPI overlay for WM1302 (`dtoverlay=spi0-1cs,cs0_pin=8`)
- GPIO reset script for SX1302 chip
- Install ChirpStack concentratord + gateway-bridge (arm64 .deb)
- Region config: EU868 channels
- Systemd units bound to `lorawan-gateway.target`

### 5.8 `lora_mesh`
- Enable SPI overlay for SX1262
- Flash RNode firmware onto SX1262 via `rnodeconf` (serial)
- Systemd unit for `rnoded` bound to `lora-mesh.target`

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
| `default_radio_profile` | `lora-mesh` | You prefer LoRaWAN gateway at boot |
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

### 6.10 Switch Radio Profiles

```bash
# On the Pi (or via SSH)
sudo /usr/local/bin/switch-profile.sh lora-mesh        # Reticulum mesh
sudo /usr/local/bin/switch-profile.sh lorawan-gateway   # ChirpStack LoRaWAN
sudo /usr/local/bin/switch-profile.sh both-off          # Disable all radios

# Or remotely via Ansible
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
| ChirpStack won't start | Check `journalctl -u chirpstack-concentratord -f` — verify WM1302 is connected and SPI overlay loaded |
| Reticulum can't find RNode | Ensure firmware is flashed (`flash-rnode.sh`), check `ls /dev/ttyS0` |
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

### Phase 3 — Stacked Hats & LoRaWAN Gateway
- [ ] Solder GPIO stacker header onto WM1302 hat
- [ ] Stack: Pi ← WM1302 (bottom, CE0) ← SX1262 (top, CE1)
- [ ] Verify both SPI devices visible: `ls /dev/spidev0.*` shows `.0` and `.1`
- [ ] Implement `switch-profile.sh` GPIO reset script
- [ ] Implement `lorawan` role (SPI overlay, ChirpStack concentratord + gateway-bridge)
- [ ] Create `lorawan-gateway.target` systemd target
- [ ] Test: activate lorawan profile, see gateway in ChirpStack web UI

### Phase 4 — LoRa Mesh / Reticulum
- [ ] Confirm SX1262 CE1 jumper setting matches DT overlay
- [ ] Flash RNode firmware with `rnodeconf --autoinstall` (script: `flash-rnode.sh`)
- [ ] Implement `reticulum` role (config, shared instance, transport node)
- [ ] Implement `lora_mesh` role (SPI overlay, rnoded, systemd target)
- [ ] Create `lora-mesh.target` systemd target
- [ ] Test: switch to lora-mesh profile, discover Pi as Reticulum transport node
- [ ] Test: switch back to lorawan, confirm clean transition

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
- [ ] Dual radio mode: test both hats active simultaneously (`dual_radio_mode: true`)

---

## 11. Useful Commands Reference

```bash
# Switch radio profile (stacked hats)
sudo scripts/switch-profile.sh lora-mesh
sudo scripts/switch-profile.sh lorawan-gateway
sudo scripts/switch-profile.sh both-off

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