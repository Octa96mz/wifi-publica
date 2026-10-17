# wifi-publica

**One-command hardening for untrusted Wi-Fi on Arch Linux (CachyOS + Omarchy/Hyprland), plus a WireGuard VPN layer with a real kill switch and multi-server switching for Proton VPN Free.**

Airports, cafés and hotels are hostile networks: anyone on them can see your
device, spoof DNS, run an evil twin, or poke at services you forgot were
listening. `wifi-publica` flips the laptop into a locked-down travel mode
and back again — reversibly, idempotently, and without editing a single
system config file.

```
$ wifi-publica on
✔ servicios detenidos: avahi-daemon.socket avahi-daemon.service cups.socket cups.service
✔ docker: pausados webapp(:8000) proxy(:80,443)
✔ MAC aleatoria en wlan0 (se reconectará)
✔ DNS cifrado (DoT: Quad9 + Cloudflare), sin LLMNR/mDNS
✔ IPv6 desactivado en wlan0
✔ firewall: tabla inet wifipublica (entrada drop, IPv4+IPv6, puertos Docker bloqueados)
✔ VPN 'NL-FREE-220' activa con kill switch (solo sale tráfico por 'home' y UDP a 192.0.2.10:51820)
```

> [!WARNING]
> **Read before using.**
> - This tool **runs as root** and **modifies your firewall** (nftables), network settings, services and VPN configuration.
> - It is provided **as is, without any warranty** (see [LICENSE](LICENSE)). You are responsible for what it does to your system.
> - **Test it at home first**, with physical access to the machine and the recovery plan in `docs/GUIA-PRUEBA.md` at hand, before relying on it on a real public network.
> - This project is **not affiliated with, endorsed by or sponsored by Proton AG or any other VPN provider**. "Proton VPN" is mentioned only as the provider it was tested with.

> [!NOTE]
> **The tool's messages are currently in Spanish** (CLI output, notifications,
> audit and the test guide in `docs/`). It was built for a Spanish-speaking
> user; the code, comments and this README document everything needed to adapt it.

## Features

**Two independent layers**

| Layer | What it does |
|---|---|
| **VPN** | Stores many WireGuard configs in `/etc/wireguard/servers/`, keeps `/etc/wireguard/home.conf` as a *symlink* to the active one so the interface is always `home`. `vpn on/off/toggle/use/next/prev/import/list/menu`. Every connection is verified: fresh handshake within 15 s **and** a public IP different from the one before the tunnel, or it is torn down. The IP is fetched through the tunnel (`curl --interface home`), retrying every second for up to 15 s because the tunnel's DNS can take a few seconds to answer; if it never answers, the tunnel stays up (the handshake is the primary proof) and a warning says so. Only an IP that *was obtained* and equals the previous one tears the tunnel down. Server switching is atomic with automatic rollback. |
| **Public Wi-Fi mode** | 13 modular measures, each with `apply` / `revert` / `check`: nftables firewall, Docker exposure, listening services, random MAC, generic hostname, encrypted DNS, IPv6, auto-connect to open networks, Bluetooth discovery, Tailscale, session lock, VPN + kill switch, optional throw-away browser. |

**Engineering properties**

- **Reversible** – previous state is saved to `/run/wifi-publica/state.json` before any change; `off` restores exactly that state. `/run` is tmpfs, so a reboot is an extra safety net.
- **Runtime-only** – `nft`, `sysctl -w`, `systemctl stop` (never `disable`), `nmcli connection modify --temporary` (in memory, never written to `/etc/NetworkManager`). No system config file is edited.
- **Idempotent** – `on` twice is safe; if you switch networks while active, `on` moves the measures to the new connection.
- **Transactional** – a failure halfway through `on` triggers a rollback of everything already applied (EXIT trap, `set -euo pipefail`). nftables changes are single atomic transactions.
- **Never bricks the network** – `off` or `sudo nft delete table inet wifipublica` always restores connectivity. The VPN step only enables the kill switch *after* the tunnel is verified.
- **Least privilege** – two root-owned entry points: everyday actions run passwordless, but importing a server lives in a separate executable that always asks for your password. Both validate every argument and refuse to run if their own files are writable by anyone but root.
- **Dry run** – `--dry-run` prints every command and the full nftables ruleset without touching anything.
- **No dependencies** beyond what Arch already ships (bash, nftables, NetworkManager, systemd, wireguard-tools, curl).

## Installation

```bash
git clone <this repo> && cd wifi-publica
./tests/run.sh                       # pure-function tests, touch nothing
unshare -rn ./tests/netns-killswitch.sh   # functional kill-switch test in an isolated netns
less install.sh                      # read it first
./install.sh --dry-run               # no sudo: runs the tests on a staged copy, validates sudoers, lists what it would create
sudo ./install.sh
```

`install.sh` copies the code to `/usr/local/lib/wifi-publica` (root-owned),
links `/usr/local/bin/wifi-publica`, creates `/etc/wireguard/servers` (700),
migrates an existing `/etc/wireguard/home.conf` into it (keeping a backup)
and replaces it with the symlink, installs a `visudo`-validated sudoers
drop-in, a tmpfiles rule and logrotate config. It never overwrites anything
without asking. `sudo ./uninstall.sh` reverts all of it, restoring
`home.conf` as a regular file.

### Status bar (Omarchy shell) and keybindings

Omarchy's bar is a Quickshell process, not Waybar. Two QML modules are
provided:

- `bar/modules/wifipublica-vpn.qml` — shield icon. Green: connected · amber: stale handshake · red: error · grey: off. Tooltip: server, public IP, handshake age, bytes in/out. Left click: toggle · right click: server picker · **Shift + scroll**: next/previous server (plain scroll does nothing, so an accidental scroll never switches servers; the script notifies the result).
- `bar/modules/wifipublica-mode.qml` — padlock. Green: active with VPN · amber: active without VPN / captive portal · red: kill switch with no tunnel (no internet by design) · grey: inactive. Left click: toggle · right click: captive portal.

Copy them to `~/.config/omarchy/bar/modules/` and add the entries from
`bar/shell.json.snippet.jsonc`. Instead of Waybar's `RTMIN` signals, the
modules watch `/run/wifi-publica/rev`, which the script rewrites after each
action, for instant refresh (plus a 5 s poll). Both read
`wifi-publica status --json`, which needs no password; the handshake age (root-only)
is fetched through the sudoers rule and cached for 30 s.

Keybindings for Omarchy's Lua config are in `hypr/bindings.lua`
(`SUPER+ALT+W` toggle mode, `SUPER+SHIFT+ALT+W` portal, `SUPER+ALT+V` toggle
VPN, `SUPER+SHIFT+ALT+V` server menu). Check for conflicts with
`omarchy menu keybindings --print`.

## Usage

```
wifi-publica on [--keep-docker] [--keep-tailscale] [--browser]
wifi-publica off
wifi-publica toggle
wifi-publica status [--json]
wifi-publica portal [--seconds 180]
wifi-publica audit
wifi-publica --dry-run on

wifi-publica vpn import ~/Downloads/vpn/*.conf        # up to 20 files, one password prompt
wifi-publica vpn import ~/Downloads/x.conf MY-NAME     # single file with a custom name
sudo /usr/local/lib/wifi-publica/bin/wifi-publica-import remove NL-FREE-16   # delete a saved server (password)
wifi-publica vpn list
wifi-publica vpn use NL-FREE-16
wifi-publica vpn on | off | toggle | next | prev | status
wifi-publica vpn menu          # walker --dmenu, falls back to fuzzel / wofi
```

### Managing servers (Proton VPN Free)

Proton Free lets you download one WireGuard `.conf` per server. Import a
whole folder in one call (up to 20 files, a single password prompt). Quote
paths with spaces, and preview with `--dry-run` first (no password, nothing
written):

```bash
wifi-publica --dry-run vpn import ~/Downloads/vpn/*.conf
wifi-publica vpn import ~/Downloads/vpn/*.conf
```

Every file goes through the full secure path independently, with its own
temporary copy. Invalid files (forbidden keys, symlinks, FIFOs, files not
owned by you, invalid or already-used names) are **skipped** without aborting
the batch and without prompting. Existing servers are **never overwritten**:
the final file is published with an atomic hard link (`ln -T`) that fails if
the name exists. Two files describing the same server (same endpoint and peer
public key) trigger a warning. Importing never changes the active server.

To delete a saved server: `sudo /usr/local/lib/wifi-publica/bin/wifi-publica-import remove <name>`. It lives only in the password-protected executable, accepts exactly one valid name (no globs, no options), deletes only a regular root-owned `600` file in `servers/` without following symlinks, and refuses while the VPN or the kill switch is active or if the server is the active one (switch first with `vpn use`). It uses `shred -u`, but on btrfs (copy-on-write, compression) and with snapshots (snapper) that does not guarantee the key is unrecoverable from disk; revoke a compromised key in Proton's dashboard.
The summary lists imported / skipped / failed files with the reason (file
name, line number and key name only) and prints the exact `shred -u -- …`
command to delete the originals, which contain your private key. If the
batch is interrupted (Ctrl+C, SIGTERM), every server already imported is
complete and valid, and temporary files are removed (or purged on the next
run after a `kill -9`).

`import` validates the file against an **allow-list of keys**
(`PrivateKey Address DNS MTU` / `PublicKey PresharedKey AllowedIPs Endpoint PersistentKeepalive`),
requires exactly one `[Interface]` and one `[Peer]`, a `DNS` line and an
`Endpoint`; rejects hostname endpoints (the kill switch needs an IP, and DNS
is not resolved mid-batch); and stores a sanitised copy as
`/etc/wireguard/servers/<name>.conf` (`600 root:root`). It never prints or
logs key material. The source is opened exactly once; type, owner (your
`SUDO_UID`) and size are checked on the open descriptor
(`/proc/self/fd/N`), and the data is read from that same descriptor, so
swapping the path for a symlink between check and read (TOCTOU) does not
work.

`vpn use <server>` is atomic: validate target → remember previous → bring
tunnel down → repoint the symlink → if the kill switch is active, replace
**only** the endpoint rule (`nft replace rule … handle N`) → bring tunnel up
and verify → on failure, roll everything back to the previous server.

### Captive portals

`wifi-publica portal` pauses DoT, the VPN and the kill switch, opens only DNS
(53), HTTP (80) and HTTPS (443) outbound, and schedules `wifi-publica on`
with `systemd-run --on-active=180s` (cancelled if you run `on`/`off` first).
Open <http://neverssl.com> to trigger the portal page and never type real
passwords into it.

### Example audit

```
$ wifi-publica audit
Audit wifi pública — 2026-10-13 18:40:12 — modo active
  MEDIDA       ESTADO DETALLE
  services     ✔ OK     ningún servicio de red expuesto
  docker       ✔ OK     sin contenedores con puertos públicos activos
  bluetooth    ✔ OK     no visible ni emparejable
  autoconnect  ✔ OK     ninguna wifi abierta se conecta sola
  tailscale    ✔ OK     Tailscale activo pero bloqueado por el firewall
  hostname     ✔ OK     hostname genérico 'localhost' y sin envío por DHCP; hostnamectl puede mostrar 'archlinux' (...)
  mac          ✔ OK     wlan0 usa una MAC distinta de la de fábrica
  dns          ✔ OK     DNS por el túnel (10.2.0.1, dominio ~.): sin fugas
  ipv6         ✔ OK     IPv6 desactivado en wlan0
  firewall     ✔ OK     entrada drop + kill switch en la salida
  vpn          ✔ OK     VPN 'NL-FREE-220' (handshake hace 41s) con kill switch
  session      ! AVISO  bloqueo tras 300s

  Puntuación: 99/100  (11 ok, 1 avisos, 0 mal, 0 n/a)
```

The DNS check is a real leak test: it compares the resolver actually in use
(`resolvectl`) with the expected one (`10.2.0.1` with routing domain `~.` on
the tunnel, or strict DoT to Quad9/Cloudflare without VPN) and fails if
`/etc/resolv.conf` bypasses `systemd-resolved`.

## How the kill switch works

A dedicated `table inet wifipublica` (IPv4 + IPv6) at priority `-100`, so it
coexists with ufw and Docker: a `drop` in any nftables base chain is final,
so this table can only *restrict*, never open.

```
input   policy drop: lo, established/related, DHCP, ND
forward drop new DNAT'd connections (Docker published ports), nothing new in from the tunnel;
        with kill switch: containers may only egress through the tunnel
output  (kill switch) policy drop: lo, oifname "home",
        UDP to the active server's endpoint IP:port (handshake), DHCP
```

There is intentionally **no** `established,related accept` on output, so
connections opened before the kill switch are cut too. Verified in an
isolated network namespace by `tests/netns-killswitch.sh`.

## Threat model

**Protects against**

- **Other users on the same network**: inbound connections are dropped (IPv4 and IPv6), discovery protocols (mDNS, LLMNR, SSDP, Bluetooth) are silenced, and services like sshd, CUPS, Samba, Syncthing and Docker-published apps (web apps, reverse proxies…) are stopped or paused.
- **Evil twin / rogue access points**: auto-connect to saved *open* networks is disabled; with the VPN, a malicious AP only sees encrypted WireGuard traffic.
- **Local sniffing**: with the VPN everything leaves inside the tunnel; without it, DNS is still encrypted (DoT).
- **DNS spoofing / hijacking**: strict DoT or DNS through the tunnel, never the network's resolver. The audit detects leaks.
- **Cross-network tracking by the hotspot**: random MAC, generic hostname, hostname not sent via DHCP, IPv6 (SLAAC) disabled on the uplink.

**Does NOT protect against**

- **The network operator seeing metadata without the VPN**: destination IPs and TLS SNI remain visible, plus traffic volume and timing.
- **Phishing**, malicious captive portals asking for credentials, or anything you type into a website.
- **Malware** already on the machine, or browser exploits.
- **Anonymity**: this is network hygiene, not Tor. Browser fingerprinting, accounts and cookies still identify you.
- **The VPN provider**: Proton VPN Free sees your real IP and all tunnel traffic metadata. You are moving trust from the café to Proton, not eliminating it.

## Limitations

- **Screen lock**: Omarchy's idle service only exposes enable/disable over IPC, so the tool re-enables auto-lock if "stay awake" is on, but cannot shorten the timeout without editing `~/.config/omarchy/shell.json` (it tells you the actual value).
- **NetworkManager temporary changes**: if you save the active connection from a GUI while the mode is on, the temporary values become permanent. Turn the mode off first.
- **Hostname**: only the kernel (transient) hostname changes, in memory; `off` restores the exact previous value. An app that cached the old name keeps using it.
  - systemd treats `localhost` as "unset", so while the mode is on `hostnamectl` shows its fallback name (`DefaultHostname`, `archlinux` on Arch) even though the kernel hostname is `localhost`. Check the real value with `cat /proc/sys/kernel/hostname`.
  - With a static hostname (`/etc/hostname`), NetworkManager re-imposes it on network events (`policy: set-hostname: set hostname to '…' (from system configuration)` in the journal), e.g. when the `home` interface disappears during `vpn use/next/prev`. wifi-publica re-applies the generic name at the end of its own commands (`on`, the portal and its reactivation, `vpn on/off/use/next/prev`, including the bar actions, which run these same commands). Events outside the tool (Wi-Fi reconnect, roaming, DHCP) are not covered: there is no background watcher by design. The audit then shows a warning explaining that NetworkManager restored the hostname; run `wifi-publica on` to re-apply it. The hostname is still not sent via DHCP, and mDNS/LLMNR are off, so the network does not see it.
- **Tailscale with `--keep-tailscale` and the kill switch**: the data path is allowed, but the control plane (HTTPS to Tailscale's servers) may still be blocked.
- **Docker hairpin traffic** (container → published port on the host) is blocked while the mode is active.
- **Handshake age in the bar** needs root, so it is cached for 30 s (each refresh is a `sudo -n` call logged by sudo; see the optional `!syslog` line in `sudoers/wifi-publica`).
- **A single peer per config.** This matches Proton's format and keeps the kill switch exact.
- **Tested on**: CachyOS (kernel 7.2), Omarchy shell (Quickshell), Hyprland 0.56 (Lua config), NetworkManager 1.58, nftables 1.1.7, wireguard-tools 1.0.20260223, walker 2.17.2. Other versions may differ (see comments in the code).

## Project layout

```
bin/wifi-publica        dispatcher (user front-end + root back-end, passwordless rule)
bin/wifi-publica-import server import only (password rule)
lib/                    common (log, run/dry-run, validation), state (flat JSON), cli (args +
                        routing), import, sudoers (generator),
                        parse (pure parsers), wgconf (validator), nft (ruleset
                        generator), nm (NetworkManager queue), vpn (VPN layer)
measures/*.sh           one file per measure: m_<name>_apply / _revert / _check
bar/                    Omarchy shell QML modules + shell.json snippet
hypr/bindings.lua       keybindings (Omarchy Lua format)
sudoers/                example sudoers drop-in
tests/                  run.sh (pure-function tests, incl. privilege separation), netns-killswitch.sh
docs/GUIA-PRUEBA.md     safe step-by-step test plan (Spanish)
install.sh / uninstall.sh
```

## Security notes

To report a vulnerability, see [SECURITY.md](SECURITY.md).

- **Two sudoers rules, two executables, no argument globs.**
  ```
  you ALL=(root) NOPASSWD: /usr/local/lib/wifi-publica/bin/wifi-publica
  Defaults!/usr/local/lib/wifi-publica/bin/wifi-publica-import timestamp_timeout=0
  you ALL=(root) PASSWD:   /usr/local/lib/wifi-publica/bin/wifi-publica-import
  ```
  sudo picks a rule by the file being executed (path, or device/inode when reached through another path), never by matching arguments. Argument wildcards are easy to evade: a password rule for `wifi-publica vpn import *` does not match `--yes vpn import f`, which would fall through to the passwordless rule. The passwordless executable does not even load the import code (`lib/import.sh`), and its routing table matches commands exactly (case-sensitive, exact argument count). `timestamp_timeout=0` disables sudo's credential cache for imports. Without this split, malware running as your user could silently import its own WireGuard server and route all your traffic through it.
- `vpn use` / `next` / `prev` can only activate servers already imported: a regular, root-owned `600` file in `/etc/wireguard/servers` whose name contains no path separators. Symlinks and files readable by others are rejected.
- Every argument reaches the scripts as root, so they reject control characters and overlong arguments, whitelist sub-commands and options, validate server names, ports, IPs, UUIDs and container IDs, and only import files owned by the invoking user.
- Code executed as root must be owned by root and not writable by anyone else (including every parent directory). Otherwise your user could edit the script and run anything as root without a password. The script verifies this on every privileged start (`verify_install_integrity`).
- `PreUp/PostUp/PreDown/PostDown` are rejected on import: wg-quick runs them as root, which would turn "import a config" into "run arbitrary code as root".
- No private keys in code, logs, notifications or tests. Tests use fake keys and RFC 5737/3849 documentation IPs.

## License

[MIT](LICENSE) © 2026 Octa96mz
