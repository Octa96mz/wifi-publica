# shellcheck shell=bash
# Importación de servidores. Este fichero SOLO lo carga bin/wifi-publica-import,
# que el sudoers permite únicamente CON contraseña. bin/wifi-publica (regla sin
# contraseña) no lo carga, así que no puede importar aunque se le pase
# cualquier argumento.
#
# El fichero de origen se abre UNA sola vez; dueño, tipo y tamaño se
# comprueban sobre el descriptor abierto (/proc/<pid>/fd/N), no sobre la ruta,
# y se lee de ese mismo descriptor. Así no hay ventana entre comprobar y leer
# (TOCTOU) en la que cambiar la ruta por un enlace a un fichero de root.
#
# La clave privada solo existe en: el fichero de origen, la copia temporal
# dentro de /etc/wireguard/servers (700 root) y el servidor final (600 root).
# Nunca se imprime: los errores solo contienen números de línea y nombres de
# clave.

# Temporales en /etc/wireguard/servers: ".import-src.XXXXXX" y
# ".import-out.XXXXXX". Nunca terminan en ".conf", así que vpn list/next/prev
# (que solo miran *.conf) jamás los toman por un servidor.
IMPORT_TMP_PREFIX=".import-"
IMPORT_MAX_BYTES=8192
WP_IMPORT_TMPS=()
IMPORT_FD="" IMPORT_ERR=""

# Trampa EXIT: borra los temporales de esta importación.
import_cleanup() {
  local f
  for f in "${WP_IMPORT_TMPS[@]}"; do
    case $f in
      "$WG_SERVERS/$IMPORT_TMP_PREFIX"*) rm -f -- "$f" ;;
      /tmp/wp-import.*) rm -rf --one-file-system -- "$f" ;;
    esac
  done
  WP_IMPORT_TMPS=()
}

# Restos de importaciones anteriores interrumpidas (kill -9, apagón). Se
# llama con el bloqueo tomado, así que no hay otra importación en curso.
import_purge_stale() {
  local f
  [[ -d $WG_SERVERS ]] || return 0
  while IFS= read -r -d '' f; do
    rm -f -- "$f"
    log "borrado temporal huérfano de una importación anterior: ${f##*/}"
  done < <(find "$WG_SERVERS" -maxdepth 1 -type f -name "${IMPORT_TMP_PREFIX}*" -print0)
}

# Tipo de fichero a partir del modo en hexadecimal de stat (%f), sin depender
# del idioma: S_IFREG = 0x8000.
_is_regular_mode() { [[ $1 =~ ^[0-9a-fA-F]+$ ]] && (( (16#$1 & 16#F000) == 16#8000 )); }

# fd_owned_regular <fd> <uid>: comprueba el fichero REALMENTE abierto en ese
# descriptor: regular, del uid indicado y de ≤ IMPORT_MAX_BYTES.
fd_owned_regular() {
  local fd=$1 uid=$2 info mode owner size
  [[ $fd =~ ^[0-9]+$ && $uid =~ ^[0-9]+$ ]] || return 1
  info=$(stat -L -c '%f %u %s' -- "/proc/$BASHPID/fd/$fd" 2>/dev/null) || return 1
  read -r mode owner size <<<"$info"
  _is_regular_mode "$mode" || return 1
  [[ $owner == "$uid" ]] || return 1
  (( size <= IMPORT_MAX_BYTES ))
}

# open_owned_regular <ruta> <uid>: abre la ruta una vez y deja el descriptor
# en IMPORT_FD. En caso de error deja el motivo en IMPORT_ERR y devuelve 1.
# Llamar SIN $(...) para conservar el descriptor.
open_owned_regular() {
  local path=$1 uid=$2 mode fd
  IMPORT_FD="" IMPORT_ERR=""
  # 1) Antes de abrir, con lstat (stat sin -L no sigue enlaces): rechaza
  #    enlaces simbólicos, FIFOs, dispositivos y directorios, y evita
  #    bloquearse al abrir un FIFO.
  if ! mode=$(stat -c '%f' -- "$path" 2>/dev/null); then
    IMPORT_ERR="no existe o no es accesible"; return 1
  fi
  if ! _is_regular_mode "$mode"; then
    IMPORT_ERR="no es un fichero regular (enlace simbólico, FIFO, dispositivo o directorio)"; return 1
  fi
  # 2) Una sola apertura. bash no permite O_NONBLOCK ni O_NOFOLLOW: si entre
  #    1) y 2) la ruta se sustituye, 3) lo detecta sobre el descriptor. Lo
  #    único que no evita es que una sustitución por un FIFO deje esta orden
  #    esperando; solo te afecta a ti y se corta con Ctrl+C.
  if ! exec {fd}<"$path"; then
    IMPORT_ERR="no se pudo abrir"; return 1
  fi 2>/dev/null
  # 3) Autoridad final: lo que se ha abierto de verdad.
  if ! fd_owned_regular "$fd" "$uid"; then
    exec {fd}<&-
    IMPORT_ERR="lo abierto no es un fichero regular tuyo de ≤${IMPORT_MAX_BYTES} bytes"
    return 1
  fi
  IMPORT_FD=$fd
}

# ---------------------------------------------------------------------------
#  Importación por lotes
# ---------------------------------------------------------------------------
# IMPORT_REAL=1 solo cuando el importador escribe de verdad (root y sin
# --dry-run). Lo fija bin/wifi-publica-import; nunca se lee del entorno.
IMPORT_REAL=0
IMPORT_WANT_UID="" IMPORT_CWD="" IMPORT_DRY_DIR="" IMPORT_MSG=""
declare -gA IMPORT_SEEN=()   # nombre → fichero de origen (en este lote)
declare -gA IMPORT_FP=()     # "endpoint|clave pública" → nombre del servidor
IMPORT_WORLD_READABLE=()     # originales legibles por otros usuarios

# Borra un temporal concreto y lo quita de la lista de limpieza.
import_drop_tmp() {
  local f=$1 keep=() x
  [[ -n $f ]] && rm -f -- "$f"
  for x in "${WP_IMPORT_TMPS[@]}"; do [[ $x == "$f" ]] || keep+=("$x"); done
  WP_IMPORT_TMPS=("${keep[@]}")
}

# Huella de un servidor para detectar duplicados de contenido. Usa el
# endpoint y la clave PÚBLICA del peer; nunca se imprime.
_import_fingerprint() { printf '%s|%s' "$WGC_EP_HOST:$WGC_EP_PORT" "$WGC_PEER_PUB"; }

# Indexa los servidores ya guardados (solo los activables: 600, del dueño
# esperado y no enlaces).
import_index_existing() {
  local n
  IMPORT_FP=()
  while IFS= read -r n; do
    [[ -n $n ]] || continue
    wgconf_check "$(vpn_server_file "$n")" >/dev/null 2>&1 || continue
    IMPORT_FP["$(_import_fingerprint)"]=$n
  done < <(vpn_servers 2>/dev/null)
}

# import_one <fichero> [nombre]: aplica a UN fichero el flujo completo
# (apertura única por descriptor, dueño = IMPORT_WANT_UID, validación por
# lista blanca, saneado) con su propia copia temporal, que se borra antes de
# volver. Nunca pregunta y nunca sobrescribe.
# Devuelve 0 = importado, 2 = omitido, 1 = error; el motivo queda en
# IMPORT_MSG (sin contenido del fichero: solo nº de línea y nombre de clave).
import_one() {
  local src=$1 name=${2:-} copy out dest perm fp prev
  IMPORT_MSG=""
  [[ $src == /* ]] || src="$IMPORT_CWD/$src"

  [[ -n $name ]] || name=$(server_name_from_file "$src")
  if ! valid_server_name "$name"; then
    IMPORT_MSG="nombre de servidor no válido ('$name'): renómbralo o impórtalo solo con [nombre]"
    return 2
  fi
  if [[ -n ${IMPORT_SEEN[$name]:-} ]]; then
    IMPORT_MSG="nombre '$name' repetido en el lote (ya lo aporta ${IMPORT_SEEN[$name]##*/})"
    return 2
  fi
  dest=$(vpn_server_file "$name")
  if [[ -e $dest || -L $dest ]]; then
    IMPORT_MSG="ya existe '$name' en $WG_SERVERS (no se sobrescribe)"
    return 2
  fi

  # Copia temporal propia de este fichero.
  if (( IMPORT_REAL )); then
    copy=$(mktemp "$WG_SERVERS/${IMPORT_TMP_PREFIX}src.XXXXXX") || { IMPORT_MSG="no se pudo crear el temporal"; return 1; }
  else
    copy=$(mktemp "$IMPORT_DRY_DIR/src.XXXXXX") || { IMPORT_MSG="no se pudo crear el temporal"; return 1; }
  fi
  WP_IMPORT_TMPS+=("$copy")

  if ! open_owned_regular "$src" "$IMPORT_WANT_UID"; then
    IMPORT_MSG=$IMPORT_ERR; import_drop_tmp "$copy"; return 1
  fi
  if ! head -c $(( IMPORT_MAX_BYTES + 1 )) <&"$IMPORT_FD" >"$copy"; then
    exec {IMPORT_FD}<&-
    IMPORT_MSG="error al leer"; import_drop_tmp "$copy"; return 1
  fi
  perm=$(stat -L -c '%a' -- "/proc/$BASHPID/fd/$IMPORT_FD" 2>/dev/null || echo 600)
  exec {IMPORT_FD}<&-
  chmod 600 "$copy"

  if ! wgconf_check "$copy" >/dev/null; then
    IMPORT_MSG="no válido: $(IFS=';'; printf '%s' "${WGC_ERRORS[*]}")"
    import_drop_tmp "$copy"; return 1
  fi
  if (( ! WGC_EP_IS_IP )); then
    # No se resuelve DNS en mitad de un lote: el kill switch necesita una IP.
    IMPORT_MSG="el Endpoint es un nombre de host ($WGC_EP_HOST); descarga la versión con IP"
    import_drop_tmp "$copy"; return 2
  fi
  fp=$(_import_fingerprint)
  prev=${IMPORT_FP[$fp]:-}
  if [[ -n $prev ]]; then
    warn "${src##*/}: mismo servidor (Endpoint y clave pública del peer) que '$prev'; se importa igualmente como '$name'"
  fi

  if (( ! IMPORT_REAL )); then
    IMPORT_SEEN[$name]=$src
    IMPORT_FP[$fp]=$name
    [[ $perm =~ ^[0-7]+$ ]] && (( 8#$perm & 8#077 )) && IMPORT_WORLD_READABLE+=("$src")
    import_drop_tmp "$copy"
    IMPORT_MSG="(dry-run) se importaría como '$name'"
    return 0
  fi

  # Escritura: temporal saneado y revalidado → sync → enlace duro atómico al
  # nombre final. "ln -T" falla si el destino ya existe, así que nunca
  # sobrescribe (ni siquiera ante una carrera) y el servidor aparece completo
  # o no aparece. El temporal nunca termina en .conf.
  out=$(mktemp "$WG_SERVERS/${IMPORT_TMP_PREFIX}out.XXXXXX") || { IMPORT_MSG="no se pudo crear el temporal"; import_drop_tmp "$copy"; return 1; }
  WP_IMPORT_TMPS+=("$out")
  if ! ( umask 077; wgconf_sanitize "$copy" "" >"$out" ); then
    IMPORT_MSG="error al sanear"; import_drop_tmp "$out"; import_drop_tmp "$copy"; return 1
  fi
  import_drop_tmp "$copy"
  if (( EUID == 0 )); then chown root:root "$out"; fi
  chmod 600 "$out"
  if ! wgconf_check "$out" >/dev/null; then
    IMPORT_MSG="el resultado saneado no es válido"; import_drop_tmp "$out"; return 1
  fi
  sync -- "$out" 2>/dev/null || true
  if ! ln -T -- "$out" "$dest" 2>/dev/null; then
    IMPORT_MSG="ya existe '$name' en $WG_SERVERS (no se sobrescribe)"; import_drop_tmp "$out"; return 2
  fi
  import_drop_tmp "$out"
  IMPORT_SEEN[$name]=$src
  IMPORT_FP[$fp]=$name
  [[ $perm =~ ^[0-7]+$ ]] && (( 8#$perm & 8#077 )) && IMPORT_WORLD_READABLE+=("$src")
  log "servidor importado: $name (endpoint $WGC_EP_HOST:$WGC_EP_PORT)"
  IMPORT_MSG="importado como '$name' (endpoint $WGC_EP_HOST:$WGC_EP_PORT)"
  return 0
}

# Importa IMPORT_FILES (con IMPORT_NAME si es uno solo). Un fallo en un
# fichero no detiene el resto. No toca home.conf ni el servidor activo.
# Devuelve 0 si no hubo errores (los omitidos no cuentan como error).
cmd_vpn_import() {
  local f rc label total n_ok=0 n_skip=0 n_err=0 saved
  local -a lines_ok=() lines_skip=() lines_err=() imported=()
  # shellcheck disable=SC2034  # WP_CMD lo lee log() en lib/common.sh
  WP_CMD="vpn import"
  (( ${#IMPORT_FILES[@]} )) || die "no hay ficheros que importar" 2

  # Solo ficheros de quien invoca sudo (SUDO_UID lo pone sudo; con env_reset
  # y sin SETENV no se puede falsificar). Sin sudo: el propio usuario.
  IMPORT_WANT_UID=${SUDO_UID:-$EUID}
  valid_uint "$IMPORT_WANT_UID" || die "SUDO_UID no válido"
  # Rutas relativas: respecto al directorio desde el que lanzaste la orden
  # (sudo lo conserva). getcwd real, no la variable PWD del entorno.
  IMPORT_CWD=$(pwd -P) || die "no se puede determinar el directorio de trabajo"

  if (( IMPORT_REAL )); then
    if (( EUID == 0 )); then install -d -m 700 -o root -g root "$WG_SERVERS"
    else install -d -m 700 "$WG_SERVERS"   # solo en los tests (sin root)
    fi
  else
    # dry-run: nada se escribe en /etc; temporales en un directorio 700 de /tmp.
    IMPORT_DRY_DIR=$(mktemp -d /tmp/wp-import.XXXXXX)
    WP_IMPORT_TMPS+=("$IMPORT_DRY_DIR")
  fi
  IMPORT_SEEN=()
  IMPORT_WORLD_READABLE=()
  import_index_existing

  total=${#IMPORT_FILES[@]}
  for f in "${IMPORT_FILES[@]}"; do
    label=${f##*/}
    rc=0
    import_one "$f" "$IMPORT_NAME" || rc=$?
    case $rc in
      0) n_ok=$((n_ok + 1)); lines_ok+=("$label: $IMPORT_MSG"); imported+=("$f") ;;
      2) n_skip=$((n_skip + 1)); lines_skip+=("$label: $IMPORT_MSG") ;;
      *) n_err=$((n_err + 1)); lines_err+=("$label: $IMPORT_MSG") ;;
    esac
  done

  say ""
  say "${C_BOLD}Resumen${C_RESET} ($total ficheros): $n_ok importados · $n_skip omitidos · $n_err con error"
  for f in "${lines_ok[@]}"; do printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$f"; done
  for f in "${lines_skip[@]}"; do printf '  %s↷%s %s\n' "$C_YELLOW" "$C_RESET" "$f"; done
  for f in "${lines_err[@]}"; do printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$f"; done

  if (( IMPORT_REAL )); then
    saved=$(vpn_servers | grep -c . || true)
    say "Servidores guardados ahora: $saved (el servidor activo no ha cambiado; usa 'wifi-publica vpn use <nombre>')"
    (( n_ok )) && bump_rev
  elif (( EUID == 0 )); then
    saved=$(vpn_servers | grep -c . || true)
    say "Servidores guardados: $saved; tras importar serían $(( saved + n_ok )) (dry-run: no se ha escrito nada)"
  else
    say "Dry-run sin root: no se ha escrito nada ni se pueden contar los servidores guardados"
  fi
  if (( n_ok )); then
    say "Los originales contienen tu clave privada. Cuando compruebes la importación, puedes borrarlos con:"
    printf '  shred -u --'
    printf ' %q' "${imported[@]}"
    printf '\n'
    if (( ${#IMPORT_WORLD_READABLE[@]} )); then
      warn "${#IMPORT_WORLD_READABLE[@]} de ellos son legibles por otros usuarios del equipo"
    fi
  fi
  (( n_err == 0 ))
}
