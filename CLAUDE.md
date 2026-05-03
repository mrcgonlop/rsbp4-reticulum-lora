# CLAUDE.md — PiRelay Project Context

## What this is
Ansible playbook to provision a Raspberry Pi 4 as a **Reticulum / LoRa mesh relay** and lightweight server (Gitea, Samba, Cockpit, Nginx). Target OS is **Raspberry Pi OS Lite trixie (Debian 13) arm64**.

The primary radio device is a **LilyGO T-Beam v1.2** connected via USB, running RNode firmware. The Pi has no usable radio HAT — see "Hardware history" below.

## Architecture rules
- **Ansible-only provisioning.** No manual steps on the Pi beyond flashing the SD card and a one-time `rnodeconf --autoinstall` to flash the T-Beam. Every configuration change goes through a role.
- **Idempotent.** Running `site.yml` twice must produce zero changes on the second run.
- **Minimal footprint.** No Docker, no Snap, no Flatpak. Services run as native systemd units or pip-installed Python packages.
- **T-Beam via USB.** The LilyGO T-Beam v1.2 connects as a USB serial device (`/dev/ttyUSB0` or `/dev/ttyACM0`). Flash once with `rnodeconf --autoinstall`, then Reticulum's `RNodeInterface` talks to it.
- **lora-mesh.target is enabled on boot.** It pulls in `reticulum.service` and `lxmf-propagation.service`. No runtime detection, no profile switching.
- **Meshtastic role is disabled** (`meshtastic_enable: false`). It requires a direct-SPI SX1262 HAT, which the user does not have. Re-enable only if a compatible HAT (non-UART, non-E22) is obtained.

## Hardware history
The user has two Pi HATs that are **not usable** for this project:
- **Waveshare SX1262 868M LoRa HAT (E22-900T22S)**: UART-based EBYTE module. Meshtastic and Reticulum both need raw SPI access to the SX1262 chip; the E22 module doesn't expose that. Cannot be flashed with RNode or Meshtastic firmware.
- **Seeed Wio-WM6108 (Wi-Fi HaLow)**: Only communicates with other HaLow (802.11ah) devices, not standard WiFi. Useless without a second HaLow device.

## Repository layout
```
pirelay/
├── inventory/hosts.yml
├── group_vars/all.yml        <- all tunables live here, not scattered in roles
├── roles/{base,networking,nginx,cockpit,gitea,samba,meshtastic,lora_mesh,reticulum,halow,monitoring}/
│   ├── tasks/main.yml
│   ├── handlers/main.yml
│   ├── templates/
│   └── files/
├── playbooks/site.yml
├── files/                    <- shared static files (nftables.conf, etc.)
├── templates/                <- shared Jinja2 templates
└── scripts/flash-rnode.sh    <- one-time RNode firmware flash helper
```

## Conventions
- Ansible YAML style: 2-space indent, `true`/`false` (not yes/no), quoted strings only when YAML requires it.
- Role variables: prefix with role name (e.g. `gitea_version`, `rnode_frequency`). Defaults go in `group_vars/all.yml`, not `roles/*/defaults/`.
- Templates use `.j2` extension. Config files use their native extension in `files/`.
- Handlers: use `notify` + handler name, not `command` inline restarts.
- Every role must have a tag matching its directory name (e.g. `tags: [gitea]`).
- Shell scripts in `scripts/` use `#!/usr/bin/env bash` and `set -euo pipefail`.
- **`site.yml` must `vars_files: - ../group_vars/all.yml`** — the group_vars/ directory is at the repo root, not adjacent to the inventory or playbook, so Ansible doesn't auto-load it.
- **Third-party apt repos must select the correct distro release.** The Pi runs trixie (Debian 13). Use `ansible_distribution_release` to pick the right subrepo dynamically (see meshtastic role for the pattern). On OBS repos, use `Debian_13` for arm64 (Raspbian_13 only publishes armhf).

## Key technical details
- **Reticulum:** install via `pip install rns lxmf --break-system-packages`. Config at `/etc/reticulum/config`. Shared instance mode, transport enabled. `reticulum.service` and `lxmf-propagation.service` both enabled on boot and part of `lora-mesh.target`.
- **RNode (T-Beam):** flash once with `rnodeconf --autoinstall` via USB. The T-Beam then appears as a serial RNode device that Reticulum's `RNodeInterface` talks to.
- **Meshtastic (disabled):** `meshtasticd` installed from OBS Debian_13 arm64 repo, web UI from GitHub meshtastic/web releases. Requires a direct-SPI SX1262 HAT (not the E22-900T22S UART module). Gated by `meshtastic_enable`.
- **pip on trixie:** Debian's PEP 668 enforcement blocks system-wide pip installs. Use `--break-system-packages` for system services, or `pipx install --global` for CLI tools (meshtastic CLI uses pipx).
- **Gitea:** single binary install to `/usr/local/bin/gitea`, data in `/var/lib/gitea/`, SQLite backend.
- **Cockpit:** bind to 127.0.0.1:9090, fronted by Nginx with websocket proxy. Origins must include all hostname/IP variants the user accesses from (including `ansible_default_ipv4.address`).
- **Nginx:** all services behind reverse proxy. Paths: `/` -> Cockpit, `/gitea/` -> Gitea.
- **mDNS:** use `avahi-daemon` (Pi OS default). Do **not** install `systemd-resolved` — it fights avahi over port 5353.
- **Firewall:** nftables, default-deny INPUT. Ports from `group_vars/all.yml:firewall_allowed_tcp_ports` are rendered into the template dynamically.

## What NOT to do
- Don't install Docker or container runtimes.
- Don't reintroduce the WM1302 / ChirpStack / LoRaWAN path without explicit user request.
- Don't reintroduce `pirelay-detect-hat` / `radio_detect` role / `switch-profile.sh` / dual-profile targets.
- Don't use `apt` deprecated key method — use `/etc/apt/keyrings/` for third-party repos.
- Don't hardcode IPs or GPIO pin numbers — use variables from `group_vars/all.yml`.
- Don't create roles that combine unrelated services.
- Don't use `shell:` when `apt:`, `copy:`, `template:`, `systemd:` modules work.
- Don't install a desktop environment or GUI packages.
- Don't install `systemd-resolved` — use `avahi-daemon` for mDNS.
- Don't put `avahi-daemon` in `disable_services` — the networking role needs it running.
- Don't assume the Waveshare E22-900T22S HAT works with Meshtastic or Reticulum — it's UART-only and incompatible.

## Testing approach
- Use `--check --diff` for dry runs before applying.
- After each role, verify with a simple smoke test (port open? service active? config valid?).
- On first provision, the `base` role reboots once (hostname + SPI config changes). If running Ansible *on the Pi locally*, the play will drop at the reboot — re-run the same command after the Pi comes back; idempotent tasks skip and the play resumes.

## Phase priority
Work in order: base -> networking -> nginx -> cockpit -> gitea -> samba -> lora_mesh -> reticulum -> halow -> monitoring.

## Spain-specific
- Timezone: Europe/Madrid
- Locale: en_US.UTF-8 (user preference, not es_ES)
- LoRa: EU868 band, 14 dBm ERP, 1% duty cycle on most sub-bands
- Wi-Fi HaLow: regulatory status uncertain under CNMC — experimental only, gated by `halow_enable`
