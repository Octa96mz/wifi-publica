# Security Policy

`wifi-publica` runs as root and changes the firewall, network and VPN
configuration of the machine, so security reports are taken seriously.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

- Use GitHub's private reporting: **Security → Report a vulnerability** in
  this repository (if it is not available, open an issue asking for a
  private contact channel, without technical details).
- Include the affected version or commit, your distribution and versions
  of NetworkManager / nftables / wireguard-tools, steps to reproduce, and
  the impact (e.g. privilege escalation, kill-switch bypass, DNS leak).
- **Never include private keys, real WireGuard configs, IPs or hostnames**
  in a report. Use the fake keys and RFC 5737/3849 documentation addresses
  from `tests/lib.sh`.

You should receive an acknowledgement within 7 days. Fixes are released as
soon as practical and credited to the reporter unless you prefer otherwise.

## In scope

- Privilege escalation through the sudoers rules or the root entry points
  (`bin/wifi-publica`, `bin/wifi-publica-import`).
- Kill-switch bypass, traffic or DNS leaks while the mode is active.
- Import path issues (TOCTOU, symlinks, hook keys such as `PostUp`).
- Leaking key material to logs, notifications or the terminal.

## Out of scope

- Threats listed under "Does NOT protect against" in the README.
- Vulnerabilities in the VPN provider, NetworkManager, nftables,
  WireGuard or other upstream software (report those upstream).
