# shellcheck shell=bash
# Medida 12: VPN + kill switch (usa la capa VPN de lib/vpn.sh).
# Orden seguro: endpoint resuelto → VPN arriba y verificada → kill switch.
# Si la VPN no levanta en 15 s solo se revierte la parte VPN: el kill switch
# nunca queda a medias.

m_vpn_apply() {
  local name was_up pre
  if ! have wg-quick || ! have wg; then
    warn "falta wireguard-tools: VPN no aplicable (sudo pacman -S wireguard-tools)"
    st_set vpn.killswitch 0
    return 0
  fi
  if ! name=$(vpn_active_server) || [[ ! -e $WG_LINK ]]; then
    warn "sin VPN: dominios y metadatos visibles para la red (no hay $WG_LINK)"
    st_set vpn.killswitch 0
    return 0
  fi
  if ! vpn_load_server "$name"; then
    warn "sin VPN: el servidor activo '$name' no es válido"
    st_set vpn.killswitch 0
    return 0
  fi
  st_set vpn.ep_ip "$VPN_EP_IP" vpn.ep_port "$VPN_EP_PORT" vpn.server "$name"

  if vpn_is_up; then was_up=1; else was_up=0; fi
  st_has vpn.was_up || st_set vpn.was_up "$was_up"

  if (( ! was_up )); then
    pre=$(st_get pre_ip 2>/dev/null || true)
    if ! vpn_up_checked "$pre"; then
      warn "sin VPN: no se pudo conectar a '$name'. Modo activo SIN kill switch (dominios y metadatos visibles para la red)"
      st_set vpn.killswitch 0
      return 0
    fi
  elif (( ! DRY_RUN )); then
    local hs; hs=$(vpn_handshake_epoch)
    if (( $(date +%s) - hs > 180 )); then
      warn "la VPN estaba arriba pero sin handshake reciente; se activa igualmente el kill switch"
    fi
  fi
  st_set vpn.killswitch 1
  fw_rebuild
  ok "VPN '$name' activa con kill switch (solo sale tráfico por '$WG_IFACE' y UDP a $VPN_EP_IP:$VPN_EP_PORT)"
}

m_vpn_revert() {
  local was_up
  was_up=$(st_get vpn.was_up 2>/dev/null || echo 1)
  st_set vpn.killswitch 0
  if [[ $was_up == 0 ]]; then vpn_down || warn "no se pudo bajar la VPN"; fi
  st_del vpn.was_up
  if have nft && nft_table_exists; then fw_rebuild; fi
}

m_vpn_check() {
  have wg || { echo "na|falta wireguard-tools"; return; }
  [[ -e $WG_LINK ]] || { echo "bad|sin VPN configurada: dominios y metadatos visibles para la red"; return; }
  if ! vpn_is_up; then
    if killswitch_on; then echo "bad|kill switch activo SIN túnel: sin internet por diseño"
    else echo "bad|VPN apagada: dominios y metadatos visibles para la red"; fi
    return
  fi
  local hs age
  hs=$(vpn_handshake_epoch); age=$(( $(date +%s) - hs ))
  if (( hs == 0 || age > 180 )); then echo "bad|túnel sin handshake reciente"; return; fi
  if killswitch_on; then echo "ok|VPN '$(vpn_active_server)' (handshake hace ${age}s) con kill switch"
  else echo "warn|VPN '$(vpn_active_server)' activa, pero sin kill switch"
  fi
}
