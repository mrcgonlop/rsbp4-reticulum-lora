# CLAUDE.md — PiRelay Project Context

## What this is
Ansible playbook to provision a Raspberry Pi 4 as a **Reticulum / LoRa mesh relay** (Waveshare SX1262 868M HAT) and lightweight server (Gitea, Samba, Cockpit, Nginx). Target OS is Raspberry Pi OS Lite Bookworm arm64.

## Architecture rules
- **Ansible-only provisioning.** No manual steps on the Pi beyond flashing the SD card and a one-time `rnodeconf --autoinstall` to flash RNode firmware onto the SX1262. Every configuration change goes through a role.
- **Idempotent.** Running `site.yml` twice must produce zero changes on the second run.
- **Minimal footprint.** No Docker, no Snap, no Flatpak. Services run as native systemd units or pip-installed Python packages.
- **SX1262 only.** The only supported radio HAT is the Waveshare SX1262 868M LoRa HAT on SPI0 CE1 + GPIO 22 reset + GPIO 27 BUSY + GPIO 4 DIO1. The WM1302 / ChirpStack / LoRaWAN path was removed — this Pi is a Reticulum/LoRa mesh node, not a LoRaWAN gateway.
- **lora-mesh.target is enabled on boot.** It pulls in `reticulum.service` and `lxmf-propagation.service`. No runtime detection, no profile switching.

## Repository layout
```
pirelay/
├── inventory/hosts.yml
├── group_vars/all.yml        ← all tunables live here, not scattered in roles
├── roles/{base,networking,nginx,cockpit,gitea,samba,lora_mesh,reticulum,halow,monitoring}/
│   ├── tasks/main.yml
│   ├── handlers/main.yml
│   ├── templates/
│   └── files/
├── playbooks/site.yml
├── files/                    ← shared static files (nftables.conf, etc.)
├── templates/                ← shared Jinja2 templates
└── scripts/flash-rnode.sh    ← one-time RNode firmware flash helper
```

## Conventions
- Ansible YAML style: 2-space indent, `true`/`false` (not yes/no), quoted strings only when YAML requires it.
- Role variables: prefix with role name (e.g. `gitea_version`, `rnode_frequency`). Defaults go in `group_vars/all.yml`, not `roles/*/defaults/`.
- Templates use `.j2` extension. Config files use their native extension in `files/`.
- Handlers: use `notify` + handler name, not `command` inline restarts.
- Every role must have a tag matching its directory name (e.g. `tags: [gitea]`).
- Shell scripts in `scripts/` use `#!/usr/bin/env bash` and `set -euo pipefail`.
- **`site.yml` must `vars_files: - ../group_vars/all.yml`** — the group_vars/ directory is at the repo root, not adjacent to the inventory or playbook, so Ansible doesn't auto-load it.

## Key technical details
- **SPI:** default `dtparam=spi=on` exposes CE0 (spidev0.0) and CE1 (spidev0.1). The SX1262 HAT uses CE1. No stacked/multi-CS overlays needed.
- **Reticulum:** install via `pip install rns lxmf --break-system-packages`. Config at `/etc/reticulum/config`. Shared instance mode, transport enabled. `reticulum.service` and `lxmf-propagation.service` both enabled on boot and part of `lora-mesh.target`.
- **RNode firmware:** flash SX1262 once with `rnodeconf --autoinstall` (wrapper at `/usr/local/bin/flash-rnode.sh`). The HAT then exposes a serial RNode device that Reticulum's `RNodeInterface` talks to.
- **Gitea:** single binary install to `/usr/local/bin/gitea`, data in `/var/lib/gitea/`, SQLite backend.
- **Cockpit:** bind to 127.0.0.1:9090, fronted by Nginx with websocket proxy.
- **Nginx:** all services behind reverse proxy. Paths: `/` → Cockpit, `/gitea` → Gitea.
- **mDNS:** use `avahi-daemon` (Pi OS default). Do **not** install `systemd-resolved` — it isn't in Bookworm's default install and fights avahi over port 5353.
- **Firewall:** nftables, default-deny INPUT. Only open ports listed in `group_vars/all.yml:firewall_allowed_tcp_ports`.

## What NOT to do
- Don't install Docker or container runtimes.
- Don't reintroduce the WM1302 / ChirpStack / LoRaWAN path without explicit user request — it was deliberately removed.
- Don't reintroduce `pirelay-detect-hat` / `radio_detect` role / `switch-profile.sh` / dual-profile targets — the architecture is single-HAT, enabled on boot.
- Don't use `apt` deprecated key method — use `/etc/apt/keyrings/` for third-party repos.
- Don't hardcode IPs or GPIO pin numbers — use variables from `group_vars/all.yml`.
- Don't create roles that combine unrelated services.
- Don't use `shell:` when `apt:`, `copy:`, `template:`, `systemd:` modules work.
- Don't install a desktop environment or GUI packages.
- Don't install `systemd-resolved` — use `avahi-daemon` for mDNS.
- Don't put `avahi-daemon` in `disable_services` — the networking role needs it running.

## Testing approach
- Use `--check --diff` for dry runs before applying.
- After each role, verify with a simple smoke test (port open? service active? config valid?).
- On first provision, the `base` role reboots once (hostname + SPI config changes). If running Ansible *on the Pi locally*, the play will drop at the reboot — re-run the same command after the Pi comes back; idempotent tasks skip and the play resumes.

## Phase priority
Work in order: base → networking → nginx → cockpit → gitea → samba → lora_mesh → reticulum → halow → monitoring.

## Spain-specific
- Timezone: Europe/Madrid
- Locale: en_US.UTF-8 (user preference, not es_ES)
- LoRa: EU868 band, 14 dBm ERP, 1% duty cycle on most sub-bands
- Wi-Fi HaLow: regulatory status uncertain under CNMC — experimental only, gated by `halow_enable`
