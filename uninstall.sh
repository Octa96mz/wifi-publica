#!/usr/bin/env bash
# Desinstala wifi-publica y deja el sistema como estaba:
#   sudo ./uninstall.sh
# - Desactiva el modo si está activo (restaura red, servicios, Docker...).
# - Restaura /etc/wireguard/home.conf como fichero normal (desde la copia
#   home.conf.pre-wifi-publica o, si no existe, desde el servidor activo).
# - Pregunta antes de borrar los servidores guardados y el registro.
set -euo pipefail

DEST=/usr/local/lib/wifi-publica
BIN_LINK=/usr/local/bin/wifi-publica
SUDOERS=/etc/sudoers.d/wifi-publica
TMPFILES=/etc/tmpfiles.d/wifi-publica.conf
LOGROTATE=/etc/logrotate.d/wifi-publica
LOG=/var/log/wifi-publica.log
WG_DIR=/etc/wireguard
WG_SERVERS=$WG_DIR/servers
WG_LINK=$WG_DIR/home.conf
WG_BACKUP=$WG_DIR/home.conf.pre-wifi-publica
RUN=/run/wifi-publica

say()  { printf '%s\n' "$*"; }
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
die()  { printf '\e[31m✗ %s\e[0m\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 [s/N] " a; a=${a,,}; [[ $a == s* || $a == y* ]]; }

[[ $EUID -eq 0 ]] || die "ejecuta: sudo $0"
[[ -t 0 ]] || die "el desinstalador es interactivo: ejecútalo en una terminal"
USER_NAME=$(sed -n 's/^user=//p' "$DEST/.install-manifest" 2>/dev/null || true)
USER_NAME=${USER_NAME:-${SUDO_USER:-}}

step "Modo wifi pública"
mode=$(sed -n 's/^ *"mode": "\(.*\)",\{0,1\}$/\1/p' "$RUN/state.json" 2>/dev/null || true)
if [[ -n $mode && $mode != inactive ]]; then
  say "El modo está '$mode'. Hay que desactivarlo para restaurar red, servicios y Docker."
  ask "¿Ejecutar 'wifi-publica off' ahora?" || die "cancelado: ejecuta 'wifi-publica off' y vuelve a intentarlo"
  "$DEST/bin/wifi-publica" off || die "'off' falló: revisa /var/log/wifi-publica.log antes de desinstalar"
else
  say "✔ inactivo"
fi
systemctl stop wifi-publica-portal.timer >/dev/null 2>&1 || true
if nft list table inet wifipublica >/dev/null 2>&1; then
  nft delete table inet wifipublica && say "✔ tabla nft wifipublica eliminada"
fi

step "WireGuard"
if [[ -L $WG_LINK ]]; then
  target=$(readlink -f "$WG_LINK" || true)
  if [[ -f $WG_BACKUP ]]; then
    say "Se restaurará $WG_LINK desde la copia original ($WG_BACKUP)."
    if [[ -n $target && -f $target ]] && ask "¿Prefieres restaurarlo con el servidor ACTIVO ahora ($(basename "$target"))?"; then
      install -m 600 -o root -g root "$target" "$WG_DIR/.home.conf.tmp"
      rm -f "$WG_BACKUP"
    else
      mv -f "$WG_BACKUP" "$WG_DIR/.home.conf.tmp"
    fi
  elif [[ -n $target && -f $target ]]; then
    install -m 600 -o root -g root "$target" "$WG_DIR/.home.conf.tmp"
  else
    die "$WG_LINK es un enlace roto y no hay copia: revisa $WG_SERVERS a mano"
  fi
  chmod 600 "$WG_DIR/.home.conf.tmp"; chown root:root "$WG_DIR/.home.conf.tmp"
  mv -Tf "$WG_DIR/.home.conf.tmp" "$WG_LINK"
  say "✔ $WG_LINK es de nuevo un fichero normal (600)"
  [[ -d /sys/class/net/home ]] && say "  (la VPN 'home' sigue activa; 'sudo wg-quick down home' para apagarla)"
else
  say "✔ $WG_LINK no es un enlace: no se toca"
fi
if [[ -d $WG_SERVERS ]]; then
  say "$WG_SERVERS contiene $(find "$WG_SERVERS" -maxdepth 1 -name '*.conf' | wc -l) servidores con tus claves privadas."
  if ask "¿Borrarlos de forma segura (shred)?"; then
    find "$WG_SERVERS" -maxdepth 1 -type f -exec shred -u {} +
    rmdir "$WG_SERVERS"
    say "✔ servidores eliminados"
  else
    say "✔ se conservan en $WG_SERVERS"
  fi
fi

step "Ficheros del sistema"
rm -f "$SUDOERS" && say "✔ $SUDOERS"
rm -f "$TMPFILES" "$LOGROTATE" && say "✔ tmpfiles y logrotate"
if [[ -L $BIN_LINK && $(readlink "$BIN_LINK") == "$DEST/bin/wifi-publica" ]]; then rm -f "$BIN_LINK" && say "✔ $BIN_LINK"; fi
if [[ -d $DEST ]]; then rm -rf --one-file-system -- "${DEST:?}" && say "✔ $DEST"; fi
if [[ -d $RUN ]]; then rm -rf --one-file-system -- "${RUN:?}" && say "✔ $RUN"; fi
if [[ -f $LOG ]] && ask "¿Borrar el registro $LOG?"; then rm -f "$LOG" && say "✔ registro eliminado"; fi

step "Configuración de usuario"
if [[ -n $USER_NAME ]]; then
  home=$(getent passwd "$USER_NAME" | cut -d: -f6)
  mods=("$home/.config/omarchy/bar/modules/wifipublica-mode.qml" "$home/.config/omarchy/bar/modules/wifipublica-vpn.qml")
  if [[ -e ${mods[0]} || -e ${mods[1]} ]] && ask "¿Borrar los módulos QML de la barra?"; then
    runuser -u "$USER_NAME" -- rm -f "${mods[@]}" && say "✔ módulos borrados"
  fi
fi
say "Quita a mano las entradas wifipublica-* de ~/.config/omarchy/shell.json y los atajos de ~/.config/hypr/bindings.lua."
say "Hecho."
