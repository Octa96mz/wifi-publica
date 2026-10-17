# shellcheck shell=bash
# Medida 6: DNS cifrado (DoT con Quad9 y Cloudflare), sin LLMNR ni mDNS, e
# ignorando el DNS que da la red. Se hace con `nmcli --temporary` en vez de
# `resolvectl dns/dnsovertls`, porque NetworkManager reescribe los ajustes de
# resolvectl al renovar DHCP o reconectar. El resultado se verifica con resolvectl.
#
# Con VPN activa, wg-quick registra 10.2.0.1 en la interfaz "home" con el
# dominio de enrutado "~." (resolvconf -x), así que TODAS las consultas van por
# el túnel; el DoT de la wifi queda en reserva y no se usa.
#
# Aviso: muchos portales cautivos rompen DoT → usa "wifi-publica portal".

DNS_PROPS=(ipv4.dns ipv4.ignore-auto-dns ipv6.dns ipv6.ignore-auto-dns connection.dns-over-tls connection.mdns connection.llmnr)

m_dns_apply() {
  have resolvectl || { warn "falta resolvectl (systemd): DNS no aplicable"; return 0; }
  [[ -n $UPLINK_UUID ]] || { warn "DNS: sin conexión gestionada por NetworkManager (no aplicable)"; return 0; }
  if [[ $(nm_measure_target dns) == changed ]]; then m_dns_revert; fi
  local p
  if ! st_has dns.uuid; then
    st_set dns.uuid "$UPLINK_UUID"
    for p in "${DNS_PROPS[@]}"; do st_set "dns.prev.$p" "$(nm_get "$UPLINK_UUID" "$p")"; done
  fi
  nm_queue "$UPLINK_UUID" 0 \
    ipv4.ignore-auto-dns yes ipv4.dns "$DOT_SERVERS" \
    ipv6.ignore-auto-dns yes \
    connection.dns-over-tls yes connection.mdns no connection.llmnr no
  ok "DNS cifrado (DoT: Quad9 + Cloudflare), sin LLMNR/mDNS"
  warn "algunos portales cautivos no funcionan con DoT: usa 'wifi-publica portal' si no carga la página de acceso"
}

m_dns_revert() {
  local uuid p v args=()
  uuid=$(st_get dns.uuid 2>/dev/null || true)
  [[ -n $uuid ]] && valid_uuid "$uuid" || return 0
  for p in "${DNS_PROPS[@]}"; do
    v=$(st_get "dns.prev.$p" 2>/dev/null || true)
    [[ $v =~ ^[A-Za-z0-9.:#,_\ -]*$ ]] || v=""
    args+=("$p" "$v")
    st_del "dns.prev.$p"
  done
  nm_queue "$uuid" 0 "${args[@]}"
  st_del dns.uuid
}

m_dns_check() {
  have resolvectl || { echo "na|falta resolvectl"; return; }
  local ns bad_ns dev=${UPLINK_DEV:-} dot servers home_dns home_dom
  ns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')
  bad_ns=$(tr ' ' '\n' <<<"$ns" | grep -vE '^(127\.0\.0\.53|127\.0\.0\.54|)$' || true)
  if [[ -n $bad_ns ]]; then
    echo "bad|/etc/resolv.conf apunta a $bad_ns (las apps se saltan systemd-resolved)"; return
  fi
  if vpn_is_up; then
    home_dns=$(parse_resolvectl_value "$(resolvectl dns "$WG_IFACE" 2>/dev/null || true)")
    home_dom=$(parse_resolvectl_value "$(resolvectl domain "$WG_IFACE" 2>/dev/null || true)")
    if [[ $home_dns == *10.2.0.1* && $home_dom == *'~.'* ]]; then
      echo "ok|DNS por el túnel (10.2.0.1, dominio ~.): sin fugas"
    else
      echo "bad|posible fuga: el resolver esperado es 10.2.0.1 en '$WG_IFACE' y hay '$home_dns' (dominios '$home_dom')"
    fi
    return
  fi
  [[ -n $dev ]] || { echo "warn|sin interfaz de red activa"; return; }
  dot=$(parse_resolvectl_value "$(resolvectl dnsovertls "$dev" 2>/dev/null || true)")
  servers=$(parse_resolvectl_value "$(resolvectl dns "$dev" 2>/dev/null || true)")
  if [[ $dot == yes && $servers == *9.9.9.9* && $servers != *192.168.* && $servers != *10.* ]]; then
    echo "ok|DoT estricto con $servers en $dev"
  elif [[ $dot == yes ]]; then
    echo "warn|DoT activo pero con servidores inesperados: $servers"
  else
    echo "bad|DNS sin cifrar en $dev ($servers): el operador de la red ve y puede falsear tus consultas"
  fi
}
