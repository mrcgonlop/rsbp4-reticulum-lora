# PiRelay — Raspberry Pi 4 Reticulum / LoRa Mesh Relay

Ansible playbook to provision a Raspberry Pi 4 as a **Reticulum mesh relay**
and lightweight home server (Gitea, Samba, Cockpit, Nginx). The Pi sits on
your LAN via Ethernet and bridges local services to the LoRa mesh via a
USB-connected **LilyGO T-Beam** running RNode firmware.

Target OS: **Raspberry Pi OS Lite trixie (Debian 13) arm64**.

---

## 1. Hardware

| Component | Role | Interface | Status |
|---|---|---|---|
| Raspberry Pi 4 (4 GB+) | Host | Ethernet | Working |
| LilyGO T-Beam v1.2 | RNode for Reticulum + Meshtastic | USB serial (`/dev/ttyACM0`) | Working — RNode firmware 1.86, EU868 |
| MicroSD 32 GB+ (A2) | Boot/root | -- | Working |
| 5V / 3A USB-C PSU | Power | -- | **Required** (undervoltage with weaker supplies) |

### Hardware not in use

| Component | Why not | Could be useful for |
|---|---|---|
| Waveshare SX1262 868M LoRa HAT (E22-900T22S) | UART module, incompatible with Meshtastic/Reticulum (both need raw SPI radio access) | Point-to-point serial telemetry between two E22 modules |
| Seeed Wio-WM6108 (Wi-Fi HaLow) | Only talks to other HaLow devices, not standard WiFi | Long-range IoT link if paired with another HaLow device |
| Seeed WM1302 (if purchased later) | LoRaWAN gateway concentrator -- different protocol from Reticulum/Meshtastic | Private LoRaWAN IoT network with ChirpStack, or public TTN gateway |

---

## 2. Architecture

```
                         Internet
                            |
                     [Home Router]
                            |
                      eth0 (DHCP)
                   +--------+--------+
                   |    Raspberry Pi  |
                   |                  |
                   |  Cockpit (9090)  |  <-- https://pirelay.local/
                   |  Gitea   (3000)  |  <-- https://pirelay.local/gitea/
                   |  Samba (445/139) |  <-- \\pirelay.local\shared
                   |  Nginx  (80/443) |  <-- reverse proxy, self-signed TLS
                   |                  |
                   |  Reticulum       |  <-- transport node, shared instance
                   |  LXMF propagation|  <-- store-and-forward messaging
                   |                  |
                   +--------+---------+
                            |
                        USB serial
                            |
                   +--------+---------+
                   |  LilyGO T-Beam   |
                   |  (RNode firmware) |
                   |  EU868, 14 dBm   |
                   +------------------+
                            |
                        LoRa radio
                            |
                   [Reticulum mesh]
```

### Services

| Service | Port | Access |
|---|---|---|
| Cockpit (web dashboard) | 443 (via Nginx) | `https://pirelay.local/` |
| Gitea (git server) | 443 (via Nginx) | `https://pirelay.local/gitea/` |
| Samba (file shares) | 445/139 | `\\pirelay.local\shared` |
| Reticulum shared instance | 4242 | LAN clients via `TCPClientInterface` |
| SSH | 22 | Key-only authentication |

---

## 3. Ansible Structure

```
pirelay/
├── inventory/hosts.yml           # Pi IP/hostname, SSH user
├── group_vars/all.yml            # All tunables (single source of truth)
├── playbooks/site.yml            # Full deployment
├── roles/
│   ├── base/                     # OS packages, hostname, swap, SPI enable
│   ├── networking/               # nftables firewall, avahi mDNS
│   ├── nginx/                    # Reverse proxy, self-signed TLS
│   ├── cockpit/                  # Web management dashboard
│   ├── gitea/                    # Git server (single binary, SQLite)
│   ├── samba/                    # File sharing
│   ├── meshtastic/               # meshtasticd daemon (disabled -- needs SPI HAT)
│   ├── lora_mesh/                # RNode flash helpers, lora-mesh.target
│   ├── reticulum/                # Reticulum + LXMF services
│   ├── halow/                    # Wi-Fi HaLow (experimental, gated)
│   └── monitoring/               # Optional Prometheus node_exporter
├── files/                        # Static config files
├── templates/                    # Shared Jinja2 templates
└── scripts/flash-rnode.sh        # One-time RNode firmware flash helper
```

### Deployment phases

| Phase | Roles | Tags |
|---|---|---|
| 1. Foundation | `base`, `networking` | `base`, `networking` |
| 2. Core services | `nginx`, `cockpit`, `gitea`, `samba` | `nginx`, `cockpit`, `gitea`, `samba` |
| 3. Meshtastic | `meshtastic` (gated by `meshtastic_enable`) | `meshtastic` |
| 4. Reticulum | `lora_mesh`, `reticulum` | `lora_mesh`, `reticulum` |
| 5. HaLow | `halow` (experimental, gated by `halow_enable`) | `halow` |
| 6. Monitoring | `monitoring` (optional) | `monitoring` |

---

## 4. Quick Start

### Prerequisites (workstation)

```bash
pip install ansible
ansible-galaxy collection install ansible.posix community.general
```

### Flash Pi SD card

1. Use **Raspberry Pi Imager**, select **Raspberry Pi OS Lite (64-bit)**
2. In advanced settings:
   - Hostname: `pirelay`
   - Enable SSH with public-key auth
   - Username: `pi`
   - Timezone: `Europe/Madrid`
3. Write to SD, insert in Pi, boot

### Deploy

```bash
# Clone this repo
git clone <your-repo-url> pirelay && cd pirelay

# Edit inventory with your Pi's IP
nano inventory/hosts.yml

# Review variables
nano group_vars/all.yml

# Dry run
ansible-playbook playbooks/site.yml --check --diff

# Deploy (or run locally on the Pi)
ansible-playbook playbooks/site.yml
# Local: sudo ansible-playbook -i "localhost," -c local playbooks/site.yml
```

### T-Beam setup (already done, reference)

```bash
# 1. Plug T-Beam into Pi via USB (appears as /dev/ttyACM0 with CH9102 chip)
# 2. Flash RNode firmware (one-time)
sudo rnodeconf /dev/ttyACM0 --autoinstall   # pick "LilyGO T-Beam"

# 3. Verify
rnodeconf /dev/ttyACM0 --info

# 4. Bring up Reticulum
sudo systemctl start lora-mesh.target
rnstatus --config /var/lib/reticulum -A
```

---

## Connecting from your workstation

The Pi exposes Reticulum via a TCP server on **port 4242**. From any device on your LAN, install Reticulum and connect to it.

### Windows / macOS / Linux setup

```bash
pip install rns lxmf
```

Edit `~/.reticulum/config` (created on first run of `rnstatus`) and add:

```
[interfaces]
  [[PiRelay TCP]]
    type = TCPClientInterface
    interface_enabled = True
    target_host = 192.168.1.42       # your Pi's IP
    target_port = 4242
```

Now any Reticulum app on your workstation routes through the Pi to the LoRa mesh.

### Best UI options

| Tool | Platform | Best for |
|---|---|---|
| **[Sideband](https://unsigned.io/sideband/)** | Android, iOS, desktop | Daily use — polished UI, messaging, file transfer, voice. Direct LXMF inbox. |
| **[MeshChat](https://github.com/liamcottle/reticulum-meshchat)** | Web (runs anywhere) | Desktop / browser. Modern web UI, nicest visual experience on PC. |
| **NomadNet** | TUI (terminal) | Lightweight, lives over SSH, classic mesh interface with node directory. |

**Recommended for your setup:** **Sideband** on your phone (point it at the Pi's TCP interface for fast LAN connection, falls back to LoRa when out of range) + **MeshChat** on your desktop browser.

### MeshChat is preinstalled

The `meshchat` role clones [reticulum-meshchat](https://github.com/liamcottle/reticulum-meshchat) into `/opt/reticulum-meshchat`, runs it under systemd, and exposes the web UI behind nginx at:

**`https://192.168.1.42:4444/`** (or `https://pirelay.local:4444/`)

It shares the Pi's Reticulum instance, so any contact you message via MeshChat goes out over the LoRa mesh and TCP server. Disable the role by setting `meshchat_enable: false` in `group_vars/all.yml` if you don't want it.

### Discovering nearby nodes

Reticulum is decentralised — there is no global directory. Two ways to find nodes:

1. **Public map** at [map.reticulum.network](https://map.reticulum.network/) — shows nodes that have opted into the LXMF Network Map. Useful to see if there's existing activity in your city.
2. **Listen passively** — let `rnsd` run for a few hours. Any nearby Reticulum node within LoRa range will eventually announce, and you'll see them in `rnstatus -A`. Add them as contacts in Sideband/MeshChat to start messaging.

To make your own node discoverable on the public map, run:

```bash
sudo rnpath --config /var/lib/reticulum --tabulate
# follow the LXMF Network Map node opt-in instructions on its homepage
```

---

## 5. Post-deploy verification

| Check | Command |
|---|---|
| Cockpit | Browse `https://pirelay.local/` (accept self-signed cert) |
| Gitea | Browse `https://pirelay.local/gitea/` |
| Samba | Windows: `\\pirelay.local\shared` |
| Firewall | `sudo nft list ruleset` |
| Reticulum | `rnstatus` (after T-Beam is connected) |
| Services | `systemctl status nginx cockpit.socket gitea` |

---

## 6. EU868 Regulatory Notes (Spain)

- **Frequency:** 863-870 MHz ISM band, licence-free
- **Duty cycle:** 1% on most sub-bands (36 s/hour TX)
- **Max ERP:** 25 mW (14 dBm) on most sub-bands; 500 mW on g1 (869.4-869.65 MHz)
- **Reticulum/RNode:** `airtime_limit` in RNode enforces duty cycle compliance

---

## 7. Security

- SSH: key-only auth, no root login
- All web services behind Nginx with TLS
- nftables default-deny INPUT
- Cockpit restricted to LAN
- Reticulum: encrypted by design (Curve25519 + AES-256)
- Unattended apt security updates enabled

---

## 8. References

- [Reticulum Network Stack](https://reticulum.network/)
- [RNode / rnodeconf](https://github.com/markqvist/rnodeconf)
- [LXMF](https://github.com/markqvist/lxmf)
- [Meshtastic Linux Native](https://meshtastic.org/docs/hardware/devices/linux-native-hardware/)
- [Cockpit Project](https://cockpit-project.org/)
- [Gitea](https://gitea.io/)




Happy to help. Syncthing is a great addition and it usually fits neatly alongside services like Gitea/Samba since it's just an apt package + a systemd service to enable.

To guide you well and match your existing conventions, it'd help to see:

The directory structure of your Ansible project (a tree or ls -R of the repo, or just paste it) — so I know if you're using roles, a flat playbook, group_vars, etc.
The main playbook (e.g. site.yml / playbook.yml) — to see how services are included/ordered.
One existing service's role/tasks (Gitea or Samba, whichever is simpler) — so I can mirror the same pattern for Syncthing (how you install packages, enable services, handle templates/handlers, etc.).

Once I see those, here's roughly how we'll approach Syncthing:

Install: apt package (it's in the standard Raspberry Pi OS/Debian repos) — I'll double check the current recommended install method since package sources for Syncthing have changed over the years.
Run as a system service: Syncthing ships with syncthing@<user>.service as a systemd template unit, so we just need to enable/start it for the right user, rather than write a custom unit file (unless your other services do something custom that you want to match).
Config: decide if you want to manage config.xml / device IDs via Ansible (declarative) or just let Syncthing bootstrap on first run and manage folders/devices via its web UI afterward — this is worth deciding explicitly since it changes the role a lot.

Go ahead and paste or upload those files whenever you're ready.

---
# site.yml — Full PiRelay deployment
# Usage: ansible-playbook -i inventory/hosts.yml playbooks/site.yml
#        (or locally: sudo ansible-playbook -i "localhost," -c local playbooks/site.yml)
#
# Run with --check --diff for dry run.
# Use --tags to target specific roles (e.g. --tags gitea,nginx).

- name: PiRelay — Full Deployment
  hosts: all
  become: true
  gather_facts: true

  vars_files:
    - ../group_vars/all.yml

  roles:
    # Phase 1 — Foundation
    - role: base
      tags: [base]

    - role: networking
      tags: [networking]

    # Phase 2 — Core Services
    - role: nginx
      tags: [nginx]

    - role: cockpit
      tags: [cockpit]

    - role: gitea
      tags: [gitea]

    - role: samba
      tags: [samba]

    # Phase 3 — Meshtastic (Waveshare SX1262 HAT, SPI)
    - role: meshtastic
      tags: [meshtastic]
      when: meshtastic_enable | bool

    # Phase 4 — Reticulum (requires a USB RNode device, e.g. LilyGO T-Beam)
    - role: lora_mesh
      tags: [lora_mesh]

    - role: reticulum
      tags: [reticulum]

    - role: meshchat
      tags: [meshchat]
      when: meshchat_enable | bool

    # Phase 5 — Wi-Fi HaLow (experimental, gated by halow_enable)
    - role: halow
      tags: [halow]

    # Optional
    - role: monitoring
      tags: [monitoring]

  post_tasks:
    - name: Display deployment summary
      ansible.builtin.debug:
        msg: |
          ========================================
          PiRelay deployment complete!
          ========================================
          Hostname:       {{ hostname }}
          Domain:         {{ domain }}
          Cockpit:        https://{{ domain }}/
          Gitea:          https://{{ domain }}/gitea/
          SSH:            ssh pi@{{ domain }}
          Samba:          \\{{ domain }}\shared
          ========================================
          Reticulum:      rnstatus --config /var/lib/reticulum -A
                          systemctl status lora-mesh.target
          MeshChat:       https://{{ domain }}:{{ meshchat_nginx_port }}/
          ========================================
          Meshtastic:     disabled (set meshtastic_enable: true
                          when a direct-SPI SX1262 HAT is available)
      tags: [always]
the tree:

├───files
│   └───chirpstack
├───group_vars
├───inventory
├───playbooks
├───roles
│   ├───base
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───cockpit
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───gitea
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───halow
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───lora_mesh
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───meshchat
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───meshtastic
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───monitoring
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───networking
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───nginx
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   ├───reticulum
│   │   ├───files
│   │   ├───handlers
│   │   ├───tasks
│   │   └───templates
│   └───samba
│       ├───files
│       ├───handlers
│       ├───tasks
│       └───templates
├───scripts
└───templates
    └───nginx-sites

now for example for samba, the handlers:

- name: restart samba
  ansible.builtin.systemd:
    name: smbd
    state: restarted
the tasks:

# roles/samba/tasks/main.yml — File sharing
# Tags: samba

- name: Install Samba
  ansible.builtin.apt:
    name:
      - samba
      - samba-common-bin
    state: present
  tags: [samba]

- name: Create share directories
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: directory
    mode: "{{ '0775' if item.writable else '0755' }}"
  loop: "{{ samba_shares }}"
  tags: [samba]

- name: Deploy Samba configuration
  ansible.builtin.template:
    src: smb.conf.j2
    dest: /etc/samba/smb.conf
    mode: "0644"
  notify: restart samba
  tags: [samba]

- name: Enable and start Samba services
  ansible.builtin.systemd:
    name: "{{ item }}"
    enabled: true
    state: started
  loop:
    - smbd
    - nmbd
  tags: [samba]
and the template:

# {{ ansible_managed }}
# PiRelay Samba configuration

[global]
   workgroup = WORKGROUP
   server string = {{ hostname }}
   server role = standalone server
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user

   # Bind to LAN interfaces only
   interfaces = lo eth0
   bind interfaces only = yes

   # Disable NetBIOS over TCP (optional, reduces noise)
   disable netbios = yes

   # Security
   min protocol = SMB2
   encrypt passwords = true

{% for share in samba_shares %}
[{{ share.name }}]
   path = {{ share.path }}
   browseable = yes
   read only = {{ 'no' if share.writable else 'yes' }}
   create mask = 0664
   directory mask = 0775
   valid users = @sambashare

{% endfor %}

That Samba example is exactly the pattern I need — apt install → template a config → notify a handler → enable/start via systemd. Syncthing follows the same shape, with two syncthing-specific wrinkles worth flagging before I draft the role:

1. Package source. Raspberry Pi OS's own repo carries an older Syncthing build. The project's official APT repo (apt.syncthing.net) stays current and — handily — ships the syncthing@<user>.service systemd template unit already, so we don't need to write our own unit file. I'll use that repo. The first part of tasks/main.yml will look like:

yaml
- name: Ensure apt keyrings directory exists
  ansible.builtin.file:
    path: /etc/apt/keyrings
    state: directory
    mode: "0755"
  tags: [syncthing]

- name: Add Syncthing GPG key
  ansible.builtin.get_url:
    url: https://syncthing.net/release-key.gpg
    dest: /etc/apt/keyrings/syncthing-archive-keyring.gpg
    mode: "0644"
  tags: [syncthing]

- name: Add Syncthing APT repository
  ansible.builtin.apt_repository:
    repo: "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v2"
    filename: syncthing
    state: present
  tags: [syncthing]

- name: Install Syncthing
  ansible.builtin.apt:
    name: syncthing
    state: present
    update_cache: true
  tags: [syncthing]

2. Which user runs it. Your post_tasks summary block references ssh pi@{{ domain }}, so I'll default the service to syncthing@pi.service — shout if that's wrong.

3. Config ownership — this is the real fork. Syncthing's config lives in config.xml, which it also rewrites itself whenever you add a folder/device through the web GUI. So, similar to how you own smb.conf fully via the template, I can template config.xml too (looping over a syncthing_folders var just like samba_shares, with the GUI password bcrypt-hashed via Ansible's password_hash filter) — but then any folder/device added by clicking around in the GUI later gets wiped on the next playbook run unless it's also in your YAML vars. Alternatively, Ansible can just seed the file once and leave it alone afterward, GUI becomes the source of truth going forward.

Also, since Gitea and Cockpit are reverse-proxied under {{ domain }} per your summary block, I'm guessing you'll want Syncthing's GUI proxied the same way (bound to localhost, not exposed raw on 8384) — but wanted to confirm rather than assume.

How should Ansible manage Syncthing's config.xml (folders, devices, GUI settings)?
Bootstrap once — seed initial config, then manage via the GUI
Should the Syncthing GUI be reverse-proxied through nginx like Gitea/Cockpit?
Yes — proxy via nginx, bind GUI to localhost only