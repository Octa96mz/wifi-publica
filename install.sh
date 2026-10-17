#!/usr/bin/env bash
# Instalador de wifi-publica. REVÍSALO antes de ejecutarlo:
#   ./install.sh --dry-run     (sin sudo: muestra lo que haría, no escribe nada)
#   sudo ./install.sh
#
# Crea:  /usr/local/lib/wifi-publica (root, no editable por tu usuario)
#        /usr/local/bin/wifi-publica (enlace)
#        /etc/wireguard/servers (700) y migra /etc/wireguard/home.conf a un
#        enlace simbólico al servidor activo (copia de seguridad del original)
#        /etc/sudoers.d/wifi-publica (validado con visudo)
#        /etc/tmpfiles.d/wifi-publica.conf, /etc/logrotate.d/wifi-publica,
#        /var/log/wifi-publica.log
# No sobrescribe nada existente sin preguntar. No toca ~/.config salvo que
# aceptes copiar los módulos de la barra.
set -euo pipefail
umask 022

SRC=$(cd -P -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
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
MANIFEST=$DEST/.install-manifest

say()  { printf '%s\n' "$*"; }
step() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
die()  { printf '\e[31m✗ %s\e[0m\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 [s/N] " a; a=${a,,}; [[ $a == s* || $a == y* ]]; }

# Copia del proyecto (código + tests) a un directorio de preparación. La usan
# la instalación real (como root) y el dry-run (como usuario, en /tmp).
stage_copy() {
  local dir=$1 own=()
  [[ ${2:-} == root ]] && own=(-o root -g root)
  install -d -m 755 "${own[@]}" "$dir/bin" "$dir/lib" "$dir/measures" "$dir/tests" "$dir/sudoers"
  install -m 755 "${own[@]}" "$SRC/bin/wifi-publica" "$SRC/bin/wifi-publica-import" "$dir/bin/"
  install -m 644 "${own[@]}" "$SRC"/lib/*.sh "$dir/lib/"
  install -m 644 "${own[@]}" "$SRC"/measures/*.sh "$dir/measures/"
  install -m 755 "${own[@]}" "$SRC/tests/run.sh" "$dir/tests/"
  install -m 644 "${own[@]}" "$SRC"/tests/lib.sh "$SRC"/tests/test_*.sh "$dir/tests/"
  # Datos de prueba (listados reales de nft, etc.): todos los que haya.
  if [[ -d $SRC/tests/fixtures ]]; then
    install -d -m 755 "${own[@]}" "$dir/tests/fixtures"
    find "$SRC/tests/fixtures" -maxdepth 1 -type f -exec install -m 644 "${own[@]}" -t "$dir/tests/fixtures/" {} +
  fi
  install -m 644 "${own[@]}" "$SRC/sudoers/wifi-publica" "$dir/sudoers/"   # lo usa un test
}

check_deps() {
  missing=()
  for c in nft:nftables wg:wireguard-tools wg-quick:wireguard-tools resolvectl:systemd nmcli:networkmanager \
           visudo:sudo flock:util-linux runuser:util-linux curl:curl systemd-run:systemd; do
    command -v "${c%%:*}" >/dev/null || missing+=("${c%%:*} (pacman -S ${c#*:})")
  done
}

exists_or_not() { if [[ -e $1 || -L $1 ]]; then printf 'YA EXISTE (preguntaría antes de reemplazar)'; else printf 'nuevo'; fi; }

# ---------------------------------------------------------------------------
# --dry-run: como usuario, sin sudo. Solo escribe en un temporal propio de
# /tmp (que borra al salir): copia el proyecto, ejecuta los tests sobre esa
# copia, genera y valida el sudoers y muestra qué crearía/migraría.
# ---------------------------------------------------------------------------
if [[ ${1:-} == --dry-run ]]; then
  (( $# == 1 )) || die "uso: ./install.sh [--dry-run]"
  [[ $EUID -ne 0 ]] || die "el dry-run se ejecuta como tu usuario, sin sudo"
  USER_NAME=$(id -un)
  work=$(mktemp -d /tmp/wp-install-dry.XXXXXX)
  trap 'rm -rf --one-file-system -- "${work:?}"' EXIT
  step "Dry-run de install.sh (no escribe nada fuera de $work)"
  check_deps
  if (( ${#missing[@]} )); then say "Faltan:"; printf '  - %s\n' "${missing[@]}"; else say "✔ dependencias presentes"; fi
  stage_copy "$work/stage"
  "$work/stage/tests/run.sh" >/dev/null || die "los tests fallan: la instalación real se detendría aquí"
  say "✔ tests correctos sobre la copia (la instalación real hace lo mismo sobre una copia de root)"

  step "Ficheros que crearía"
  printf '  %-48s %-14s %s\n' RUTA PERMISOS ESTADO
  printf '  %-48s %-14s %s\n' "$DEST/" "755 root" "$(exists_or_not "$DEST")"
  for f in "$work/stage"/bin/* "$work/stage"/lib/*.sh "$work/stage"/measures/*.sh; do
    rel=${f#"$work/stage/"}
    printf '  %-48s %-14s\n' "$DEST/$rel" "$(stat -c %a "$f") root"
  done
  printf '  %-48s %-14s %s\n' "$BIN_LINK" "enlace" "$(exists_or_not "$BIN_LINK")"
  printf '  %-48s %-14s %s\n' "$SUDOERS" "440 root" "$(exists_or_not "$SUDOERS")"
  printf '  %-48s %-14s %s\n' "$TMPFILES" "644 root" "$(exists_or_not "$TMPFILES")"
  printf '  %-48s %-14s %s\n' "$LOGROTATE" "644 root" "$(exists_or_not "$LOGROTATE")"
  printf '  %-48s %-14s %s\n' "$LOG" "640 root" "$(exists_or_not "$LOG")"
  printf '  %-48s %-14s %s\n' "$WG_SERVERS/" "700 root" "(no legible sin root)"

  step "sudoers que instalaría (validado con visudo -cf)"
  # shellcheck source=lib/sudoers.sh
  source "$work/stage/lib/sudoers.sh"
  render_sudoers "$USER_NAME" "$DEST" >"$work/sudoers"
  visudo -cf "$work/sudoers" >/dev/null || die "visudo rechaza el sudoers generado"
  sed 's/^/  /' "$work/sudoers"
  say "  → visudo -cf: correcto"

  step "WireGuard (/etc/wireguard, $(stat -c '%a %U' "$WG_DIR" 2>/dev/null || echo 'no existe'))"
  say "  Sin root no se puede ver si $WG_LINK es un fichero o un enlace. La instalación real:"
  say "   - fichero normal → lo valida (lista blanca), pide un nombre, lo copia a servers/<nombre>.conf (600),"
  say "     guarda el original en $WG_BACKUP y lo sustituye por un enlace;"
  say "   - enlace → no lo toca;  - no existe → no hace nada (importa con 'wifi-publica vpn import')."

  step "Barra (opcional, preguntaría)"
  say "  ~/.config/omarchy/bar/modules/wifipublica-{mode,vpn}.qml  $(exists_or_not "$HOME/.config/omarchy/bar/modules/wifipublica-vpn.qml")"
  say ""
  say "Dry-run terminado: no se ha modificado nada. Para instalar: sudo ./install.sh"
  exit 0
fi

(( $# == 0 )) || die "uso: ./install.sh [--dry-run]"
[[ $EUID -eq 0 ]] || die "ejecuta: sudo $0   (o ./install.sh --dry-run para ver qué haría)"
USER_NAME=${SUDO_USER:-}
[[ -n $USER_NAME && $USER_NAME != root ]] || die "ejecútalo con sudo desde tu usuario (no como root directo)"
[[ $USER_NAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "nombre de usuario inesperado: $USER_NAME"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
[[ -t 0 ]] || die "el instalador es interactivo: ejecútalo en una terminal"

step "Comprobaciones"
check_deps
if (( ${#missing[@]} )); then
  say "Faltan (las medidas que dependan de ellos quedarán como 'no aplicable'):"
  printf '  - %s\n' "${missing[@]}"
  ask "¿Continuar igualmente?" || exit 1
else
  say "✔ dependencias presentes"
fi

step "Scripts → $DEST"
if [[ -e $DEST ]]; then
  ask "Ya existe $DEST. ¿Reemplazarlo por esta versión?" || die "instalación cancelada"
fi
# Primero se copia TODO (incluidos los tests) a un directorio de root que tu
# usuario no puede modificar; los tests se ejecutan sobre esa copia y se
# instala exactamente lo probado. Así no hay ventana entre probar y copiar en
# la que cambiar el código de ~/wifi-publica.
stage=$(mktemp -d /usr/local/lib/.wifi-publica.XXXXXX)
trap 'rm -rf --one-file-system -- "${stage:?}"' EXIT
stage_copy "$stage" root
chmod 755 "$stage"
say "Ejecutando los tests como $USER_NAME sobre la copia de root (no aplican nada al sistema)..."
runuser -u "$USER_NAME" -- "$stage/tests/run.sh" >/dev/null || die "los tests fallan: no se instala (ejecuta ./tests/run.sh para ver el detalle)"
say "✔ tests correctos"
rm -rf --one-file-system -- "${stage:?}/tests" "${stage:?}/sudoers"
if [[ -e $DEST ]]; then rm -rf --one-file-system -- "${DEST:?}"; fi
mv -T "$stage" "$DEST"
trap - EXIT
say "✔ copiado (propiedad de root, no editable por $USER_NAME)"

step "Enlace $BIN_LINK"
if [[ -L $BIN_LINK && $(readlink "$BIN_LINK") == "$DEST/bin/wifi-publica" ]]; then
  say "✔ ya existe"
elif [[ -e $BIN_LINK || -L $BIN_LINK ]]; then
  ask "$BIN_LINK ya existe y no es de wifi-publica. ¿Sustituirlo?" && ln -sfn "$DEST/bin/wifi-publica" "$BIN_LINK" || say "! no se crea el enlace"
else
  ln -s "$DEST/bin/wifi-publica" "$BIN_LINK"; say "✔ creado"
fi

step "WireGuard: $WG_SERVERS"
install -d -m 700 -o root -g root "$WG_DIR"
if [[ ! -d $WG_SERVERS ]]; then install -d -m 700 -o root -g root "$WG_SERVERS"; say "✔ creado (700)"
else chmod 700 "$WG_SERVERS"; chown root:root "$WG_SERVERS"; say "✔ ya existía (700 root:root)"; fi

migrated=""
if [[ -L $WG_LINK ]]; then
  say "✔ $WG_LINK ya es un enlace → $(readlink "$WG_LINK")"
elif [[ -f $WG_LINK ]]; then
  say "Se encontró $WG_LINK (fichero normal). Se moverá a $WG_SERVERS/<nombre>.conf"
  say "y $WG_LINK pasará a ser un enlace al servidor activo. Original guardado en $WG_BACKUP."
  # shellcheck source=/dev/null
  ( source "$DEST/lib/common.sh"; source "$DEST/lib/parse.sh"; source "$DEST/lib/wgconf.sh"
    if ! wgconf_check "$WG_LINK" >/dev/null; then
      printf '  %s\n' "${WGC_ERRORS[@]}"; exit 1
    fi ) || die "tu home.conf no supera la validación (ver arriba): corrígelo o impórtalo a mano con 'wifi-publica vpn import'"
  read -r -p "Nombre para este servidor (p. ej. NL-FREE-220): " name
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ && $name != *..* ]] || die "nombre no válido"
  if [[ -e $WG_SERVERS/$name.conf ]]; then ask "Ya existe $name.conf. ¿Sobrescribirlo?" || die "cancelado"; fi
  if [[ -e $WG_BACKUP ]]; then ask "Ya existe $WG_BACKUP. ¿Sobrescribir la copia?" || die "cancelado"; fi
  if [[ -d /sys/class/net/home ]]; then say "  (la interfaz 'home' está activa: no se ve afectada por el cambio de enlace)"; fi
  cp -p -- "$WG_LINK" "$WG_BACKUP"; chmod 600 "$WG_BACKUP"; chown root:root "$WG_BACKUP"
  install -m 600 -o root -g root "$WG_LINK" "$WG_SERVERS/$name.conf"
  ln -sfn "servers/$name.conf" "$WG_DIR/.home.conf.tmp"
  mv -Tf "$WG_DIR/.home.conf.tmp" "$WG_LINK"
  migrated=$name
  say "✔ migrado: $WG_LINK → servers/$name.conf (copia en $WG_BACKUP)"
else
  say "No hay $WG_LINK: importa servidores con 'wifi-publica vpn import <fichero.conf>'"
fi

step "sudoers"
tmp=$(mktemp)
# shellcheck source=lib/sudoers.sh
source "$DEST/lib/sudoers.sh"
render_sudoers "$USER_NAME" "$DEST" >"$tmp" || { rm -f "$tmp"; die "no se pudo generar el sudoers"; }
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "visudo rechaza el fichero generado"; }
if [[ -e $SUDOERS ]] && ! cmp -s "$tmp" "$SUDOERS"; then
  ask "$SUDOERS existe con otro contenido. ¿Sustituirlo?" || { rm -f "$tmp"; die "cancelado"; }
fi
install -m 440 -o root -g root "$tmp" "$SUDOERS"
rm -f "$tmp"
visudo -c >/dev/null || { rm -f "$SUDOERS"; die "la configuración global de sudo no valida: se retira $SUDOERS"; }
say "✔ $SUDOERS (0440, validado con visudo)"
# Si otra regla da NOPASSWD a todo (o a una shell), la contraseña de
# "vpn import" no protegería nada: avisarlo.
if sudo -l -U "$USER_NAME" 2>/dev/null | grep -qE 'NOPASSWD: *(ALL|/usr/bin/(ba|z|fi)?sh)'; then
  say "! $USER_NAME tiene sudo SIN contraseña para todo (o para una shell): 'vpn import'"
  say "  no pedirá contraseña y la separación no aporta nada. Revisa: sudo -l -U $USER_NAME"
fi

step "Estado temporal, registro y rotación"
cat >"$TMPFILES" <<'EOF'
# wifi-publica: estado temporal (se pierde al reiniciar) y fichero de refresco
d /run/wifi-publica 0755 root root -
f /run/wifi-publica/rev 0644 root root -
EOF
chmod 644 "$TMPFILES"
systemd-tmpfiles --create "$TMPFILES"
[[ -e $LOG ]] || install -m 640 -o root -g root /dev/null "$LOG"
if [[ -d /etc/logrotate.d ]]; then
  cat >"$LOGROTATE" <<EOF
$LOG {
  monthly
  rotate 6
  compress
  missingok
  notifempty
  create 0640 root root
}
EOF
  chmod 644 "$LOGROTATE"
fi
say "✔ /run/wifi-publica, $LOG"

cat >"$MANIFEST" <<EOF
# wifi-publica: lo que creó install.sh (lo usa uninstall.sh)
user=$USER_NAME
migrated=$migrated
bin_link=$BIN_LINK
EOF
chmod 644 "$MANIFEST"

step "Barra de Omarchy (opcional)"
MOD_DIR="$USER_HOME/.config/omarchy/bar/modules"
if ask "¿Copiar los módulos QML de la barra a $MOD_DIR (como $USER_NAME)?"; then
  for m in wifipublica-mode wifipublica-vpn; do
    if [[ -e $MOD_DIR/$m.qml ]] && ! ask "  $m.qml ya existe. ¿Sobrescribirlo?"; then continue; fi
    runuser -u "$USER_NAME" -- install -D -m 644 "$SRC/bar/modules/$m.qml" "$MOD_DIR/$m.qml"
    say "  ✔ $m.qml"
  done
  say "Añade las entradas de bar/shell.json.snippet.jsonc a ~/.config/omarchy/shell.json"
fi

step "Hecho"
cat <<EOF
Siguientes pasos (mira docs/GUIA-PRUEBA.md):
  1. wifi-publica --dry-run on
  2. Importa tus servidores (una sola contraseña; primero en dry-run):
       wifi-publica --dry-run vpn import ~/Downloads/vpn/*.conf
       wifi-publica vpn import ~/Downloads/vpn/*.conf
     y borra los originales (contienen tu clave privada) con el shred -u que te muestra
  3. wifi-publica vpn list / vpn use <servidor> / vpn on
  4. Atajos: hypr/bindings.lua → ~/.config/hypr/bindings.lua (comprueba conflictos)
Recuperación de emergencia: sudo nft delete table inet wifipublica; sudo wg-quick down home
EOF
