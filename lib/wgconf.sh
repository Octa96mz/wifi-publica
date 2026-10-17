# shellcheck shell=bash
# Validación y saneado de .conf de WireGuard (Proton VPN).
#
# Lista blanca de claves: wg-quick ejecuta PreUp/PostUp/PreDown/PostDown como
# root. Como el sudoers permite a tu usuario importar .conf sin contraseña,
# aceptar esas claves sería una escalada a root. Nunca se imprime ninguna
# línea del fichero: solo números de línea y nombres de clave.

WG_KEYS_INTERFACE=" PrivateKey Address DNS MTU "
WG_KEYS_PEER=" PublicKey PresharedKey AllowedIPs Endpoint PersistentKeepalive "

# Resultado de wgconf_check (globales). Llámala SIN $(...) para conservarlos:
#   if ! wgconf_check "$f" >/dev/null; then printf '%s\n' "${WGC_ERRORS[@]}"; fi
WGC_EP_HOST="" WGC_EP_PORT="" WGC_EP_IS_IP=0 WGC_DNS="" WGC_ERRORS=()
# Clave PÚBLICA del peer (no es secreta): sirve para detectar duplicados.
WGC_PEER_PUB=""

_wg_b64key() { [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }

_wg_cidr_list() {
  local item ip pfx
  IFS=',' read -r -a items <<<"$1"
  (( ${#items[@]} > 0 )) || return 1
  for item in "${items[@]}"; do
    item=${item// /}
    ip=${item%/*} pfx=${item#*/}
    [[ $item == */* ]] || return 1
    valid_uint "$pfx" || return 1
    pfx=$((10#$pfx))
    if is_ipv4 "$ip"; then (( pfx <= 32 )) || return 1
    elif is_ipv6 "$ip"; then (( pfx <= 128 )) || return 1
    else return 1
    fi
  done
}

_wg_ip_list() {
  local item
  IFS=',' read -r -a items <<<"$1"
  (( ${#items[@]} > 0 )) || return 1
  for item in "${items[@]}"; do
    item=${item// /}
    is_ip "$item" || return 1
  done
}

# parse_endpoint "host:puerto" | "[ipv6]:puerto" → WGC_EP_HOST, WGC_EP_PORT
parse_endpoint() {
  local ep=$1 host port
  if [[ $ep =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
    host=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
  elif [[ $ep =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
    host=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}
  else
    return 1
  fi
  valid_port "$port" || return 1
  WGC_EP_HOST=$host WGC_EP_PORT=$((10#$port))
  if is_ip "$host"; then WGC_EP_IS_IP=1; else WGC_EP_IS_IP=0; fi
}

# Itera las líneas útiles: imprime "nºlínea<TAB>sección<TAB>clave<TAB>valor"
# o "nºlínea<TAB>sección<TAB>[Sección]" para cabeceras.
_wg_lines() {
  local f=$1 n=0 line section="" key val
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    line=${line%%#*}
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n $line ]] || continue
    if [[ $line =~ ^\[([A-Za-z]+)\]$ ]]; then
      section=${BASH_REMATCH[1]}
      printf '%s\t%s\t[%s]\n' "$n" "$section" "$section"
    elif [[ $line =~ ^([A-Za-z]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
      printf '%s\t%s\t%s\t%s\n' "$n" "$section" "$key" "$val"
    else
      printf '%s\t%s\t!\n' "$n" "$section"
    fi
  done <"$f"
}

# wgconf_check <fichero>: devuelve 1 si no es válido; deja los errores (sin
# contenido del fichero) en WGC_ERRORS y también los imprime. Rellena
# WGC_EP_HOST/PORT/IS_IP y WGC_DNS.
wgconf_check() {
  local f=$1 n section key val errs=() ninterface=0 npeer=0
  local has_priv=0 has_addr=0 has_dns=0 has_pub=0 has_allowed=0 has_ep=0
  WGC_EP_HOST="" WGC_EP_PORT="" WGC_EP_IS_IP=0 WGC_DNS="" WGC_ERRORS=() WGC_PEER_PUB=""

  if [[ ! -f $f || -L $f ]]; then WGC_ERRORS=("no es un fichero regular")
  elif (( $(stat -c %s "$f") > 8192 )); then WGC_ERRORS=("fichero demasiado grande (>8 KiB)")
  elif LC_ALL=C grep -q '[^[:print:][:space:]]' "$f"; then WGC_ERRORS=("contiene caracteres no imprimibles")
  fi
  if (( ${#WGC_ERRORS[@]} )); then printf '%s\n' "${WGC_ERRORS[@]}"; return 1; fi

  while IFS=$'\t' read -r n section key val; do
    if [[ $key == '!' ]]; then errs+=("línea $n mal formada"); continue; fi
    if [[ $key == '['*']' ]]; then
      case $section in
        Interface) ninterface=$((ninterface + 1)) ;;
        Peer) npeer=$((npeer + 1)) ;;
        *) errs+=("línea $n: sección desconocida") ;;
      esac
      continue
    fi
    case $section in
      Interface)
        [[ $WG_KEYS_INTERFACE == *" $key "* ]] || { errs+=("línea $n: clave no permitida en [Interface]: $key"); continue; }
        case $key in
          PrivateKey) _wg_b64key "$val" && has_priv=1 || errs+=("línea $n: PrivateKey con formato inválido") ;;
          Address) _wg_cidr_list "$val" && has_addr=1 || errs+=("línea $n: Address inválida") ;;
          DNS) _wg_ip_list "$val" && { has_dns=1; WGC_DNS=${val// /}; } || errs+=("línea $n: DNS debe ser una lista de IPs") ;;
          MTU) valid_uint "$val" && (( val >= 1280 && val <= 9000 )) || errs+=("línea $n: MTU inválida") ;;
        esac ;;
      Peer)
        [[ $WG_KEYS_PEER == *" $key "* ]] || { errs+=("línea $n: clave no permitida en [Peer]: $key"); continue; }
        case $key in
          PublicKey) _wg_b64key "$val" && { has_pub=1; WGC_PEER_PUB=$val; } || errs+=("línea $n: PublicKey con formato inválido") ;;
          PresharedKey) _wg_b64key "$val" || errs+=("línea $n: PresharedKey con formato inválido") ;;
          AllowedIPs) _wg_cidr_list "$val" && has_allowed=1 || errs+=("línea $n: AllowedIPs inválido") ;;
          Endpoint) parse_endpoint "$val" && has_ep=1 || errs+=("línea $n: Endpoint inválido (host:puerto)") ;;
          PersistentKeepalive) valid_uint "$val" && (( val <= 65535 )) || errs+=("línea $n: PersistentKeepalive inválido") ;;
        esac ;;
      *) errs+=("línea $n: clave fuera de sección") ;;
    esac
  done < <(_wg_lines "$f")

  (( ninterface == 1 )) || errs+=("debe haber exactamente una sección [Interface]")
  (( npeer == 1 )) || errs+=("debe haber exactamente una sección [Peer]")
  (( has_priv )) || errs+=("falta PrivateKey")
  (( has_addr )) || errs+=("falta Address")
  (( has_dns )) || errs+=("falta la línea DNS (sin ella las consultas DNS saldrían fuera del túnel)")
  (( has_pub )) || errs+=("falta PublicKey del servidor")
  (( has_allowed )) || errs+=("falta AllowedIPs")
  (( has_ep )) || errs+=("falta Endpoint")

  WGC_ERRORS=("${errs[@]}")
  if (( ${#errs[@]} )); then
    # shellcheck disable=SC2034  # resultados WGC_* para lib/vpn.sh, lib/import.sh y tests
    WGC_EP_HOST="" WGC_EP_PORT="" WGC_EP_IS_IP=0 WGC_DNS="" WGC_PEER_PUB=""
    printf '%s\n' "${errs[@]}"
    return 1
  fi
  return 0
}

# wgconf_sanitize <fichero> [nuevo_endpoint]: escribe en stdout la versión
# normalizada (solo claves permitidas). Contiene la clave privada: redirígela
# SIEMPRE a un fichero 600, nunca a la terminal ni al registro.
wgconf_sanitize() {
  local f=$1 newep=${2:-} n section key val
  while IFS=$'\t' read -r n section key val; do
    if [[ $key == '['*']' ]]; then
      [[ $section == Peer ]] && printf '\n'
      printf '%s\n' "$key"
      continue
    fi
    if [[ $key == Endpoint && -n $newep ]]; then val=$newep; fi
    printf '%s = %s\n' "$key" "$val"
  done < <(_wg_lines "$f")
}

# Nombre de servidor a partir del fichero: nombre base sin ".conf" y sin el
# prefijo "wg-" que añade Proton ("wg-NL-FREE-16.conf" → "NL-FREE-16"). No
# se sanea: si el resultado no cumple valid_server_name, el fichero se omite.
server_name_from_file() {
  local b=${1##*/}
  b=${b%.conf}
  b=${b#wg-}
  printf '%s' "$b"
}
