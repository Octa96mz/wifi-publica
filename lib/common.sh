# shellcheck shell=bash
# Las rutas, opciones y colores de este fichero se leen desde bin/, lib/ y
# measures/, cargados con source dinámico que shellcheck no sigue:
# shellcheck disable=SC2034
# Funciones comunes: rutas, mensajes, registro, ejecución con --dry-run,
# validación de entradas, bloqueo y ejecución como el usuario de escritorio.

# --- Rutas (las de sistema las crea install.sh) -----------------------------
WP_INSTALL_DIR=/usr/local/lib/wifi-publica
WP_ROOT_BIN=$WP_INSTALL_DIR/bin/wifi-publica          # sudoers: SIN contraseña
WP_IMPORT_BIN=$WP_INSTALL_DIR/bin/wifi-publica-import  # sudoers: CON contraseña
WP_RUN=/run/wifi-publica
WP_STATE=$WP_RUN/state.json      # estado del modo (se pierde al reiniciar)
WP_VPNSTATE=$WP_RUN/vpn.json     # estado de la capa VPN (servidor, IP pública)
WP_AUDIT=$WP_RUN/audit.json      # resultado del último audit
WP_REV=$WP_RUN/rev               # se reescribe tras cada cambio (refresco de la barra)
WP_LOG=/var/log/wifi-publica.log
WG_DIR=/etc/wireguard
WG_SERVERS=$WG_DIR/servers
WG_IFACE=home                    # nombre fijo de interfaz (≤15 caracteres)
WG_LINK=$WG_DIR/$WG_IFACE.conf   # enlace simbólico al servidor activo
NFT_TABLE=wifipublica
PORTAL_UNIT=wifi-publica-portal
GENERIC_HOSTNAME=localhost
# Sintaxis "IP#nombre-TLS" en ipv4.dns: NetworkManager >= 1.48.
DOT_SERVERS="9.9.9.9#dns.quad9.net,1.1.1.1#cloudflare-dns.com"
HANDSHAKE_TIMEOUT=15

# --- Opciones globales ------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
KEEP_DOCKER=0
KEEP_TAILSCALE=0
OPT_BROWSER=0
OPT_JSON=0
OPT_PLAIN=0
PORTAL_SECONDS=180
WARNINGS=()
WP_CMD=""

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_GREY=$'\e[90m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_GREY="" C_BOLD="" C_RESET=""
fi

# --- Mensajes y registro ----------------------------------------------------
log() {
  if (( EUID == 0 && DRY_RUN == 0 )); then
    printf '%s [%s] %s\n' "$(date '+%F %T')" "${WP_CMD:-?}" "$*" >>"$WP_LOG" 2>/dev/null || true
  fi
  return 0
}
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; WARNINGS+=("$*"); log "AVISO: $*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "ERROR: $*"; }
die()  { err "$1"; exit "${2:-1}"; }

# Ejecuta un comando que modifica el sistema. Con --dry-run solo lo muestra.
run() {
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s %s\n' "$C_GREY" "$C_RESET" "$(printf '%q ' "$@")"
    return 0
  fi
  log "exec: $*"
  "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# need_cmd <comando> <paquete>: marca la medida como no aplicable si falta.
need_cmd() {
  have "$1" && return 0
  warn "falta '$1': medida no aplicable (instálalo con: sudo pacman -S $2)"
  return 1
}

is_tty() { [[ -t 0 && -t 1 ]]; }

# confirm "<pregunta>" <s|n>: sin terminal devuelve la respuesta por defecto.
confirm() {
  local q=$1 def=${2:-n} a=""
  (( ASSUME_YES )) && return 0
  if ! is_tty; then
    [[ $def == s ]]
    return
  fi
  read -r -p "$q " a || return 1
  a=${a:-$def}
  a=${a,,}
  [[ $a == s* || $a == y* ]]
}

# --- Validación -------------------------------------------------------------
valid_server_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ && $1 != *..* ]]; }
valid_uint()  { [[ $1 =~ ^[0-9]{1,9}$ ]]; }
valid_port()  { valid_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_iface() { [[ $1 =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
valid_user()  { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_uuid()  { [[ $1 =~ ^[0-9a-fA-F-]{36}$ ]]; }
valid_container_id() { [[ $1 =~ ^[0-9a-f]{12,64}$ ]]; }

is_ipv4() {
  local o='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  [[ $1 =~ ^$o\.$o\.$o\.$o$ ]]
}
is_ipv6() { [[ $1 =~ ^[0-9A-Fa-f:]{2,39}$ && $1 == *:*:* ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }

# Rechaza argumentos con caracteres de control o demasiado largos: todo
# argumento llega con privilegios de root.
validate_argv() {
  local a
  for a in "$@"; do
    (( ${#a} <= 1024 )) || die "argumento demasiado largo" 2
    [[ $a != *[[:cntrl:]]* ]] || die "argumento con caracteres de control" 2
  done
}

# --- Bloqueo y refresco -----------------------------------------------------
ensure_rundir() {
  (( DRY_RUN )) && return 0
  install -d -m 755 -o root -g root "$WP_RUN"
}

take_lock() {
  (( DRY_RUN )) && return 0
  ensure_rundir
  exec 9>"$WP_RUN/lock"
  flock -w 60 9 || die "otra instancia de wifi-publica sigue en marcha"
}

bump_rev() {
  (( DRY_RUN )) && return 0
  date +%s%N >"$WP_REV" 2>/dev/null || true
  chmod 644 "$WP_REV" 2>/dev/null || true
}

# --- Usuario de escritorio (notificaciones, idle) ----------------------------
wp_user() {
  local u=${SUDO_USER:-}
  if [[ -z $u || $u == root ]]; then
    u=$(kv_get "$WP_VPNSTATE" user 2>/dev/null || true)
  fi
  if (( EUID != 0 )); then u=$(id -un); fi
  if [[ -n $u ]] && valid_user "$u" && id -u "$u" >/dev/null 2>&1; then
    printf '%s' "$u"
    return 0
  fi
  return 1
}

# Ejecuta un comando como el usuario de escritorio (root → runuser).
as_user() {
  if (( EUID != 0 )); then "$@"; return; fi
  local u uid
  u=$(wp_user) || return 1
  uid=$(id -u "$u")
  runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

# notify <low|normal|critical> <título> <cuerpo>
notify() {
  if (( DRY_RUN )); then
    say "${C_GREY}[dry-run] notificación:${C_RESET} $2 — $3"
    return 0
  fi
  have notify-send || return 0
  as_user notify-send -a "Wifi pública" -u "$1" "$2" "$3" >/dev/null 2>&1 || true
  return 0
}

# Comprueba que el código que se ejecuta como root pertenece a root y no es
# modificable por otros usuarios (si lo fuera, sería una escalada a root).
verify_install_integrity() {
  local base=$1 p bad
  [[ $base == "$WP_INSTALL_DIR" ]] || die "como root solo se ejecuta la copia instalada en $WP_INSTALL_DIR"
  for p in / /usr /usr/local /usr/local/lib "$base"; do
    [[ $(stat -c '%u' "$p") == 0 ]] || die "$p no pertenece a root"
    [[ $(( 8#$(stat -c '%a' "$p") & 8#022 )) == 0 ]] || die "$p es escribible por grupo/otros"
  done
  bad=$(find "$base" \( ! -user root -o -perm /022 \) -print -quit)
  [[ -z $bad ]] || die "fichero inseguro en la instalación: $bad"
}
