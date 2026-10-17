# shellcheck shell=bash
# Funciones puras de parseo (sin efectos). Las prueban los tests con salidas
# simuladas de ss, nmcli, wg, docker, bluetoothctl, resolvectl, ip y nft.

# Divide una línea de `nmcli -t` respetando los ':' escapados ("\:").
# Imprime un campo por línea.
nm_split() {
  local line=$1 field="" c i
  for (( i = 0; i < ${#line}; i++ )); do
    c=${line:i:1}
    if [[ $c == '\' && $(( i + 1 )) -lt ${#line} ]]; then
      i=$(( i + 1 ))
      field+=${line:i:1}
    elif [[ $c == ':' ]]; then
      printf '%s\n' "$field"
      field=""
    else
      field+=$c
    fi
  done
  printf '%s\n' "$field"
}

# Quita los escapes de un valor de `nmcli -g`.
nm_unescape() { local s=$1; s=${s//\\:/:}; s=${s//\\\\/\\}; printf '%s' "$s"; }

# stdin: `nmcli -t -f DEVICE,TYPE,STATE device` → primer dispositivo de
# subida conectado (prefiere wifi sobre ethernet). Imprime "dev tipo".
parse_uplink() {
  local line dev type state eth=""
  while IFS= read -r line; do
    mapfile -t f < <(nm_split "$line")
    dev=${f[0]:-} type=${f[1]:-} state=${f[2]:-}
    [[ $state == connected ]] || continue
    case $type in
      wifi) printf '%s wifi\n' "$dev"; return 0 ;;
      ethernet) [[ -z $eth ]] && eth=$dev ;;
    esac
  done
  if [[ -n $eth ]]; then printf '%s ethernet\n' "$eth"; return 0; fi
  return 1
}

# stdin: `nmcli -t -f UUID,DEVICE connection show --active`; $1 = dispositivo.
parse_active_uuid() {
  local dev=$1 line
  while IFS= read -r line; do
    mapfile -t f < <(nm_split "$line")
    if [[ ${f[1]:-} == "$dev" ]]; then printf '%s\n' "${f[0]}"; return 0; fi
  done
  return 1
}

# stdin: líneas "UUID:TIPO:AUTOCONNECT:KEYMGMT:NOMBRE" (formato -t; el nombre
# va al final). Imprime "UUID<TAB>NOMBRE" de wifis abiertas con autoconexión.
parse_open_autoconnect() {
  local line uuid type auto key name
  while IFS= read -r line; do
    mapfile -t f < <(nm_split "$line")
    uuid=${f[0]:-} type=${f[1]:-} auto=${f[2]:-} key=${f[3]:-}
    name=$(IFS=:; printf '%s' "${f[*]:4}")
    [[ $type == 802-11-wireless && $auto == yes && -z $key ]] || continue
    printf '%s\t%s\n' "$uuid" "$name"
  done
}

# stdin: `ss -H -tulpn`. Imprime "proto dirección proceso" de lo que escucha
# fuera de loopback.
parse_ss_listeners() {
  local netid state laddr rest proc
  while read -r netid state _ _ laddr _ rest; do
    [[ -n ${laddr:-} ]] || continue
    case $laddr in
      # loopback, multicast y direcciones de tailscale0 (no alcanzables desde la wifi)
      127.*|\[::1\]:*|::1:*|*%lo:*|22[4-9].*|23[0-9].*|\[ff*|*%tailscale0:*) continue ;;
    esac
    proc=-
    if [[ ${rest:-} =~ \(\(\"([^\"]+)\" ]]; then proc=${BASH_REMATCH[1]}; fi
    printf '%s %s %s\n' "$netid" "$laddr" "$proc"
  done
}

# stdin: `docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}'`. Imprime
# "ID<TAB>NOMBRE<TAB>PUERTOS" de contenedores con puertos fuera de loopback.
parse_docker_public() {
  local id name ports item host addr public pubports
  while IFS=$'\t' read -r id name ports; do
    [[ -n ${id:-} ]] || continue
    public=0 pubports=""
    IFS=',' read -r -a items <<<"${ports:-}"
    for item in "${items[@]}"; do
      item=${item# }
      [[ $item == *'->'* ]] || continue
      host=${item%%->*}
      addr=${host%:*}
      case $addr in
        127.*|'[::1]'|::1) continue ;;
      esac
      public=1
      [[ ",$pubports," == *",${host##*:},"* ]] || pubports+="${pubports:+,}${host##*:}"
    done
    if (( public )); then printf '%s\t%s\t%s\n' "$id" "$name" "$pubports"; fi
  done
}

# stdin: `bluetoothctl show`; $1 = clave (Discoverable, Pairable, Powered).
parse_bt_flag() {
  local key=$1 line
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*$key:[[:space:]]*(yes|no) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

# Valor de una línea de resolvectl: "Link 3 (wlan0): a b" → "a b".
parse_resolvectl_value() {
  local l=$1
  if [[ $l == *'): '* ]]; then printf '%s' "${l#*): }"
  elif [[ $l == *'):' ]]; then printf ''
  else printf '%s' "${l#*: }"
  fi
}

# stdin: `wg show <if> latest-handshakes` → época más reciente (0 si nunca).
parse_wg_handshake() {
  local ts max=0
  while read -r _ ts; do
    [[ ${ts:-} =~ ^[0-9]+$ ]] || continue
    (( ts > max )) && max=$ts
  done
  printf '%s\n' "$max"
}

# stdin: `wg show <if> transfer` → "rx tx" sumados.
parse_wg_transfer() {
  local rx tx srx=0 stx=0
  while read -r _ rx tx; do
    [[ ${rx:-} =~ ^[0-9]+$ && ${tx:-} =~ ^[0-9]+$ ]] || continue
    srx=$(( srx + rx )) stx=$(( stx + tx ))
  done
  printf '%s %s\n' "$srx" "$stx"
}

# stdin: `nft -a list chain ...`; $1 = comentario. Imprime el handle.
parse_nft_handle() {
  local comment=$1 line
  while IFS= read -r line; do
    if [[ $line == *"comment \"$comment\""* && $line =~ \#\ handle\ ([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

# stdin: `ip link show dev X` → éxito si la MAC actual difiere de la de fábrica.
parse_ip_permaddr() { grep -q 'permaddr '; }

# Extrae un campo booleano/numérico de un JSON de una línea (salida IPC).
json_field() {
  local key=$1 json=$2
  if [[ $json =~ \"$key\":[[:space:]]*(true|false|-?[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# stdin: `nft list table ...`; $1 = cadena. Imprime la política (accept/drop)
# de esa cadena base. No depende de cómo imprima nft la prioridad: -100 se
# muestra como "-100" en input/forward pero como "dstnat" en output, y otras
# versiones usan "filter - 100".
parse_nft_chain_policy() {
  local chain=$1 line in=0
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*chain[[:space:]]+${chain}[[:space:]]*\{ ]]; then in=1; continue; fi
    (( in )) || continue
    if [[ $line =~ hook[[:space:]].*policy[[:space:]]+(accept|drop)\; ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"; return 0
    fi
    [[ $line =~ ^[[:space:]]*\}[[:space:]]*$ ]] && return 1
  done
  return 1
}

# stdin: `nft list table ...`. Éxito si hay una regla que acepta tráfico de
# la interfaz $1 (p. ej. iifname "tailscale0" accept).
parse_nft_accepts_iface() {
  local iface=$1
  grep -qE "iifname \"$iface\"( [^#]*)? accept"
}

# Valores ternarios de NetworkManager (NMTernary). `nmcli -g` los imprime como
# número: default (-1), false/no (0), true/yes (1). Se aceptan ambas formas.
nm_ternary_false() { [[ $1 =~ ^(0|no|false|off)$ ]]; }
