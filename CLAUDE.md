# CLAUDE.md — PiRelay Project Context

## What this is
Ansible playbook to provision a Raspberry Pi 4 as a multi-protocol radio relay (LoRa, LoRaWAN, Wi-Fi HaLow, Reticulum) and lightweight server (Gitea, Samba, Cockpit). Target OS is Raspberry Pi OS Lite Bookworm arm64.

## Architecture rules
- **Ansible-only provisioning.** No manual steps on the Pi beyond flashing the SD card. Every configuration change goes through a role.
- **Idempotent.** Running `site.yml` twice must produce zero changes on the second run.
- **Minimal footprint.** No Docker, no Snap, no Flatpak. Services run as native systemd units or pip-installed Python packages.
- **Stacked radio hats.** WM1302 on SPI0 CE0 (GPIO 17 reset), SX1262 on SPI0 CE1 (GPIO 22 reset). Software-switched via GPIO reset pins — only one active at a time unless `dual_radio_mode: true`.

## Repository layout
```
pirelay/
├── inventory/hosts.yml
├── group_vars/all.yml        ← all tunables live here, not scattered in roles
├── roles/{base,networking,nginx,cockpit,gitea,samba,lorawan,lora_mesh,reticulum,halow,monitoring}/
│   ├── tasks/main.yml
│   ├── handlers/main.yml
│   ├── templates/
│   └── files/
├── playbooks/{site,radio-lorawan,radio-mesh}.yml
├── files/                    ← shared static files (nftables.conf, etc.)
├── templates/                ← shared Jinja2 templates
└── scripts/                  ← helper shell scripts (switch-profile.sh, flash-rnode.sh)
```

## Conventions
- Ansible YAML style: 2-space indent, `true`/`false` (not yes/no), quoted strings only when YAML requires it.
- Role variables: prefix with role name (e.g. `gitea_version`, `lorawan_region`). Defaults go in `group_vars/all.yml`, not `roles/*/defaults/`.
- Templates use `.j2` extension. Config files use their native extension in `files/`.
- Handlers: use `notify` + handler name, not `command` inline restarts.
- Every role must have a tag matching its directory name (e.g. `tags: [gitea]`).
- Shell scripts in `scripts/` use `#!/usr/bin/env bash` and `set -euo pipefail`.

## Key technical details
- **SPI overlays:** WM1302 needs `dtoverlay=spi0-1cs,cs0_pin=8` + GPIO 17 reset. SX1262 needs CE1 on GPIO 7 + GPIO 22 reset, GPIO 27 busy, GPIO 4 DIO1.
- **Reticulum:** install via `pip install rns lxmf --break-system-packages`. Config at `/etc/reticulum/config`. Shared instance mode, transport enabled.
- **RNode firmware:** flash SX1262 with `rnodeconf --autoinstall`. The hat becomes a serial RNode device.
- **ChirpStack v4:** use .deb packages from chirpstack.io for arm64. Components: concentratord + gateway-bridge. No application server on this Pi.
- **Gitea:** single binary install to `/usr/local/bin/gitea`, data in `/var/lib/gitea/`, SQLite backend.
- **Cockpit:** bind to 127.0.0.1:9090, fronted by Nginx with websocket proxy.
- **Nginx:** all services behind reverse proxy. Paths: `/` → Cockpit, `/gitea` → Gitea, `/chirpstack` → ChirpStack.
- **Firewall:** nftables, default-deny INPUT. Only open ports listed in README §3.1.

## What NOT to do
- Don't install Docker or container runtimes.
- Don't use `apt` keys deprecated method — use `/etc/apt/keyrings/` for third-party repos.
- Don't hardcode IPs or GPIO pin numbers — use variables from `group_vars/all.yml`.
- Don't create roles that combine unrelated services.
- Don't use `shell:` when `apt:`, `copy:`, `template:`, `systemd:` modules work.
- Don't enable both radio profiles simultaneously unless `dual_radio_mode` is true.
- Don't install a desktop environment or GUI packages.

## Testing approach
- Test each phase independently (see README §10 TODO).
- Use `--check --diff` for dry runs before applying.
- After each role, verify with a simple smoke test (port open? service active? config valid?).

## Phase priority
Work in order: base → networking → nginx → cockpit → gitea → samba → lorawan → lora_mesh → reticulum → halow. Each phase builds on the previous. Don't skip ahead.

## Spain-specific
- Timezone: Europe/Madrid
- Locale: en_US.UTF-8 (user preference, not es_ES)
- LoRa: EU868 band, 1% duty cycle on most sub-bands
- Wi-Fi HaLow: regulatory status uncertain under CNMC — experimental only
