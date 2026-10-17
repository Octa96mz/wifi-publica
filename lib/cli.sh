# shellcheck shell=bash
# Este fichero solo rellena opciones globales (DRY_RUN, KEEP_*, OPT_*,
# IMPORT_FILES…) que leen bin/ y measures/; shellcheck no lo ve:
# shellcheck disable=SC2034
# Análisis de argumentos y tabla de rutas. Funciones puras (con tests): no
# ejecutan nada, solo deciden qué manejador corresponde.
#
# Separación de privilegios:
#   bin/wifi-publica         → regla sudoers SIN contraseña. route_root NO tiene
#                              ninguna ruta de importación y ese ejecutable ni
#                              siquiera carga lib/import.sh.
#   bin/wifi-publica-import  → regla sudoers CON contraseña. Solo importa.

POS=()
parse_args() {
  POS=()
  while (( $# )); do
    case $1 in
      --dry-run|-n) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --keep-docker) KEEP_DOCKER=1 ;;
      --keep-tailscale) KEEP_TAILSCALE=1 ;;
      --browser) OPT_BROWSER=1 ;;
      --json) OPT_JSON=1 ;;
      --plain) OPT_PLAIN=1 ;;
      --seconds|--seconds=*)
        local v
        if [[ $1 == *=* ]]; then v=${1#*=}; else shift; v=${1:-}; fi
        valid_uint "$v" && (( 10#$v >= 30 && 10#$v <= 900 )) || die "--seconds debe estar entre 30 y 900" 2
        PORTAL_SECONDS=$((10#$v)) ;;
      -h|--help) POS=(help); return 0 ;;
      --) shift; POS+=("$@"); break ;;
      -*) die "opción desconocida: $1 (mira: wifi-publica --help)" 2 ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
  # 4 para los comandos normales (route_root exige el número exacto);
  # "vpn import" admite hasta IMPORT_MAX_FILES ficheros + nombre.
  (( ${#POS[@]} <= 23 )) || die "demasiados argumentos" 2
}

# route_root <posicionales...>: imprime el manejador o "reject:<motivo>".
# Coincidencia EXACTA (sensible a mayúsculas) y número EXACTO de argumentos:
# "vpn IMPORT", "vpn import", "vpn ./import" o argumentos de más no tienen
# ruta. "vpn use" solo acepta un nombre de servidor (sin '/', sin '..').
route_root() {
  local n=$# cmd=${1:-} sub=${2:-}
  case "$n:$cmd:$sub" in
    1:on:|1:off:|1:toggle:|1:portal:|1:audit:)
      printf '%s\n' "$cmd" ;;
    2:vpn:on|2:vpn:off|2:vpn:toggle|2:vpn:status|2:vpn:list|2:vpn:next|2:vpn:prev|2:vpn:_probe)
      printf 'vpn_%s\n' "$sub" ;;
    3:vpn:use)
      if valid_server_name "$3"; then printf 'vpn_use\n'
      else printf 'reject:nombre de servidor no válido\n'; fi ;;
    *:vpn:import)
      printf 'reject:vpn import solo está disponible con contraseña (wifi-publica-import)\n' ;;
    *:vpn:remove)
      printf 'reject:borrar servidores solo con contraseña: sudo %s remove <nombre>\n' "$WP_IMPORT_BIN" ;;
    *)
      printf 'reject:comando no válido\n' ;;
  esac
}

# Argumentos de bin/wifi-publica-import:
#   [--yes] [--dry-run] [--] <fichero.conf>...          (1 a IMPORT_MAX_FILES)
#   [--yes] [--dry-run] [--] <fichero.conf> <nombre>    (nombre: solo con UN fichero)
# Los ficheros deben terminar en ".conf"; un último argumento sin ".conf" es
# el nombre. No se acepta ninguna otra opción. Deja el resultado en
# IMPORT_FILES e IMPORT_NAME; devuelve 2 si no son válidos.
IMPORT_MAX_FILES=20
IMPORT_MAX_ARG=1024
IMPORT_FILES=() IMPORT_NAME=""
parse_import_args() {
  local pos=() a
  IMPORT_FILES=() IMPORT_NAME=""
  while (( $# )); do
    case $1 in
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run|-n) DRY_RUN=1 ;;
      --) shift; pos+=("$@"); break ;;
      -*) echo "opción no permitida en import: $1" >&2; return 2 ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  if (( ${#pos[@]} == 0 )); then
    echo "uso: wifi-publica-import [--yes] [--dry-run] <fichero.conf>... | <fichero.conf> <nombre>" >&2
    return 2
  fi
  for a in "${pos[@]}"; do
    if (( ${#a} == 0 || ${#a} > IMPORT_MAX_ARG )); then
      echo "argumento vacío o demasiado largo (máx. $IMPORT_MAX_ARG caracteres)" >&2; return 2
    fi
    [[ $a != *[[:cntrl:]]* ]] || { echo "argumento con caracteres de control" >&2; return 2; }
  done
  if [[ ${pos[-1]} != *.conf ]]; then
    if (( ${#pos[@]} != 2 )); then
      echo "el [nombre] solo se admite con un único fichero, y los ficheros deben terminar en .conf" >&2
      return 2
    fi
    IMPORT_NAME=${pos[-1]}
    unset 'pos[-1]'
    valid_server_name "$IMPORT_NAME" || { echo "nombre no válido: usa letras, números, '.', '_' o '-' (máx. 48)" >&2; return 2; }
  fi
  for a in "${pos[@]}"; do
    [[ $a == *.conf ]] || { echo "los ficheros deben terminar en .conf" >&2; return 2; }
  done
  if (( ${#pos[@]} > IMPORT_MAX_FILES )); then
    echo "máximo $IMPORT_MAX_FILES ficheros por llamada (se recibieron ${#pos[@]})" >&2
    return 2
  fi
  IMPORT_FILES=("${pos[@]}")
  return 0
}
