# shellcheck shell=bash
# Medida 7: IPv6 desactivado en la interfaz de subida durante el modo (evita
# fugas fuera del túnel y SLAAC rastreable). ipv6.method=disabled (temporal)
# para que NetworkManager no lo reactive al reconectar + sysctl inmediato.
# La interfaz "home" no se toca: la VPN puede seguir usando IPv6 dentro del túnel.

_ipv6_sysctl_path() { printf '/proc/sys/net/ipv6/conf/%s/disable_ipv6' "$1"; }

m_ipv6_apply() {
  [[ -n $UPLINK_UUID ]] || { warn "IPv6: sin conexión gestionada por NetworkManager (no aplicable)"; return 0; }
  if [[ $(nm_measure_target ipv6) == changed ]]; then m_ipv6_revert; m_ipv6_post_revert; fi
  if ! st_has ipv6.uuid; then
    st_set ipv6.uuid "$UPLINK_UUID" ipv6.dev "$UPLINK_DEV" \
      ipv6.method "$(nm_get "$UPLINK_UUID" ipv6.method)" \
      ipv6.sysctl "$(cat "$(_ipv6_sysctl_path "$UPLINK_DEV")" 2>/dev/null || echo 0)"
  fi
  if [[ $(nm_get "$UPLINK_UUID" ipv6.method) != disabled ]]; then
    nm_queue "$UPLINK_UUID" 1 ipv6.method disabled
  fi
}

# Tras nm_commit (la reconexión podría reactivar IPv6).
m_ipv6_post_apply() {
  [[ -n $UPLINK_DEV ]] || return 0
  run sysctl -q -w "net/ipv6/conf/$UPLINK_DEV/disable_ipv6=1"
  ok "IPv6 desactivado en $UPLINK_DEV"
}

m_ipv6_revert() {
  local uuid method
  uuid=$(st_get ipv6.uuid 2>/dev/null || true)
  [[ -n $uuid ]] && valid_uuid "$uuid" || return 0
  method=$(st_get ipv6.method 2>/dev/null || echo auto)
  [[ $method =~ ^(auto|dhcp|manual|ignore|link-local|shared|disabled)$ ]] || method=auto
  nm_queue "$uuid" 1 ipv6.method "$method"
}

m_ipv6_post_revert() {
  local dev prev
  dev=$(st_get ipv6.dev 2>/dev/null || true)
  prev=$(st_get ipv6.sysctl 2>/dev/null || echo 0)
  if [[ -n $dev ]] && valid_iface "$dev" && [[ $prev =~ ^[01]$ && -e $(_ipv6_sysctl_path "$dev") ]]; then
    run sysctl -q -w "net/ipv6/conf/$dev/disable_ipv6=$prev"
  fi
  st_del ipv6.uuid ipv6.dev ipv6.method ipv6.sysctl
}

m_ipv6_check() {
  [[ -n $UPLINK_DEV ]] || { echo "na|sin conexión activa"; return; }
  if [[ $(cat "$(_ipv6_sysctl_path "$UPLINK_DEV")" 2>/dev/null) == 1 ]]; then
    echo "ok|IPv6 desactivado en $UPLINK_DEV"
  else
    echo "bad|IPv6 activo en $UPLINK_DEV (posible fuga fuera del túnel)"
  fi
}
