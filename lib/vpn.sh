# shellcheck shell=bash
# Capa VPN: varios servidores en /etc/wireguard/servers/<nombre>.conf y un
# enlace /etc/wireguard/home.conf al activo. wg-quick nombra la interfaz según
# el nombre con el que se invoca, así que siempre se llama "home" (≤15
# caracteres) y el firewall siempre sabe dónde mirar.

vpn_is_up() { [[ -d /sys/class/net/$WG_IFACE ]]; }

vpn_active_server() {
  local t
  t=$(readlink "$WG_LINK" 2>/dev/null) || return 1
  t=${t##*/}
  t=${t%.conf}
  valid_server_name "$t" || return 1
  printf '%s' "$t"
}

vpn_server_file() { printf '%s/%s.conf' "$WG_SERVERS" "$1"; }

# Un servidor solo es activable si su .conf es un fichero regular (no un
# enlace), del propietario esperado (root en uso real) y sin permisos para
# grupo/otros: solo puede haberlo creado wifi-publica-import (con contraseña).
server_file_secure() {
  local f=$1 owner=${2:-0}
  [[ -f $f && ! -L $f ]] || return 1
  [[ $(stat -c %u "$f") == "$owner" ]] || return 1
  (( (8#$(stat -c %a "$f") & 8#077) == 0 ))
}

vpn_servers() {
  local f n
  for f in "$WG_SERVERS"/*.conf; do
    server_file_secure "$f" "$EUID" || continue
    n=${f##*/}; n=${n%.conf}
    valid_server_name "$n" && printf '%s\n' "$n"
  done | sort
}

# Carga y valida el .conf de un servidor; deja el endpoint (IP) en
# VPN_EP_IP/VPN_EP_PORT. Si el endpoint es un nombre, lo resuelve AHORA
# (antes de activar el kill switch, después el DNS estaría bloqueado).
VPN_EP_IP="" VPN_EP_PORT=""
vpn_load_server() {
  local name=$1 f
  valid_server_name "$name" || { err "nombre de servidor no válido"; return 1; }
  f=$(vpn_server_file "$name")
  [[ -e $f || -L $f ]] || { err "no existe el servidor '$name' (mira: wifi-publica vpn list)"; return 1; }
  server_file_secure "$f" "$EUID" || { err "'$name' no es un servidor importado válido (enlace, propietario o permisos incorrectos)"; return 1; }
  if ! wgconf_check "$f" >/dev/null; then
    err "configuración de '$name' no válida:"
    printf '    %s\n' "${WGC_ERRORS[@]}" >&2
    return 1
  fi
  # shellcheck disable=SC2034  # lo lee el kill switch (bin/ y measures/vpn.sh)
  VPN_EP_PORT=$WGC_EP_PORT
  if (( WGC_EP_IS_IP )); then
    VPN_EP_IP=$WGC_EP_HOST
  else
    VPN_EP_IP=$(getent ahostsv4 "$WGC_EP_HOST" 2>/dev/null | awk 'NR==1{print $1}')
    is_ipv4 "${VPN_EP_IP:-}" || { err "no se pudo resolver el Endpoint de '$name'"; return 1; }
    warn "el Endpoint de '$name' es un nombre; resuelto a $VPN_EP_IP (reimpórtalo para fijar la IP)"
  fi
}

vpn_handshake_epoch() {
  wg show "$WG_IFACE" latest-handshakes 2>/dev/null | parse_wg_handshake
}

# Espera un handshake posterior a <desde> durante HANDSHAKE_TIMEOUT segundos.
vpn_wait_handshake() {
  local since=$1 i hs
  for (( i = 0; i < HANDSHAKE_TIMEOUT; i++ )); do
    hs=$(vpn_handshake_epoch)
    if (( hs >= since )); then return 0; fi
    sleep 1
  done
  return 1
}

wp_now() { date +%s; }

# _public_ip_try [interfaz] [segundos]: un intento; deja el resultado en
# PUBLIC_IP (vacío si no hay IP) y el error de curl en PUBLIC_IP_ERR. Con
# <interfaz>, curl se ata a ella (SO_BINDTODEVICE): la petición no puede salir
# por otra. El DNS sigue su camino normal (systemd-resolved).
PUBLIC_IP="" PUBLIC_IP_ERR=""
_public_ip_try() {
  local ifc=${1:-} out args=(-fsS --max-time "${2:-6}")
  [[ -n $ifc ]] && args+=(--interface "$ifc")
  out=$(curl "${args[@]}" https://api.ipify.org 2>&1 || true)
  PUBLIC_IP="" PUBLIC_IP_ERR=""
  if is_ip "$out"; then PUBLIC_IP=$out
  else PUBLIC_IP_ERR=${out//[[:cntrl:]]/ }; PUBLIC_IP_ERR=${PUBLIC_IP_ERR:0:200}
  fi
  return 0
}

public_ip() { _public_ip_try; printf '%s' "$PUBLIC_IP"; }

# IP pública a través del túnel recién subido: reintenta cada segundo hasta
# PUBLIC_IP_WAIT s y sale en cuanto responde. Justo tras "wg-quick up" el DNS
# del túnel puede tardar (systemd-resolved degrada UDP+EDNS0 → UDP → TCP).
# No abre nada en el firewall: todo sale por $WG_IFACE (permitido por el kill
# switch). Imprime la IP, o nada y devuelve 1 si no responde a tiempo.
PUBLIC_IP_WAIT=15
public_ip_via_tunnel() {
  local deadline rem n=0
  deadline=$(( $(wp_now) + PUBLIC_IP_WAIT ))
  while :; do
    n=$((n + 1))
    rem=$(( deadline - $(wp_now) ))
    (( rem > 3 )) && rem=3
    (( rem < 1 )) && rem=1
    _public_ip_try "$WG_IFACE" "$rem"
    if [[ -n $PUBLIC_IP ]]; then
      (( n > 1 )) && log "IP pública obtenida al intento $n"
      printf '%s' "$PUBLIC_IP"
      return 0
    fi
    (( $(wp_now) + 1 < deadline )) || break
    sleep 1
  done
  log "IP pública sin respuesta tras $n intentos en ${PUBLIC_IP_WAIT} s: ${PUBLIC_IP_ERR:-sin detalle}"
  return 1
}

# Sube la VPN y la verifica: handshake reciente y cambio de IP pública.
# Si algo falla la baja y devuelve 1.
vpn_up_checked() {
  local pre=${1:-} start ip
  start=$(date +%s)
  run wg-quick up "$WG_IFACE" || { err "wg-quick up falló"; vs_set last_error "wg-quick up falló"; return 1; }
  (( DRY_RUN )) && return 0
  if ! vpn_wait_handshake "$start"; then
    err "sin handshake en ${HANDSHAKE_TIMEOUT} s: bajando la VPN"
    run wg-quick down "$WG_IFACE" || true
    vs_set last_error "sin handshake"
    return 1
  fi
  ip=$(public_ip_via_tunnel) || ip=""
  # Solo una IP OBTENIDA e idéntica a la anterior indica que el tráfico no va
  # por el túnel. Sin respuesta no se sabe nada: manda el handshake.
  if [[ -n $pre && -n $ip && $ip == "$pre" ]]; then
    err "la IP pública no cambió ($ip): bajando la VPN"
    run wg-quick down "$WG_IFACE" || true
    vs_set last_error "la IP pública no cambió"
    return 1
  fi
  [[ -n $ip ]] || warn "túnel verificado por handshake; la IP pública no respondió en ${PUBLIC_IP_WAIT} s (el DNS del túnel puede tardar en arrancar). No es un fallo de la VPN: compruébala luego con 'curl https://api.ipify.org'"
  vs_set public_ip "$ip" last_error "" up_since "$(date +%s)"
  return 0
}

vpn_down() {
  vpn_is_up || return 0
  run wg-quick down "$WG_IFACE"
}

# Apunta home.conf a otro servidor de forma atómica (enlace + rename).
vpn_point_link() {
  local name=$1 tmp="$WG_DIR/.home.conf.tmp"
  run ln -sfn "servers/$name.conf" "$tmp"
  run mv -Tf "$tmp" "$WG_LINK"
  vs_set server "$name"
}

# Comprueba si el modo wifi pública tiene el kill switch activo.
killswitch_on() { [[ $(st_get vpn.killswitch 2>/dev/null || echo 0) == 1 ]]; }
mode_is_active() { local m; m=$(mode_get); [[ $m == active || $m == portal || $m == applying ]]; }
