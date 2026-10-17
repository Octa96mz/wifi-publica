# shellcheck shell=bash
# Medida 4: MAC aleatoria en la conexión activa (cloned-mac-address=random,
# temporal). Requiere reconectar; se hace una sola vez junto a las demás
# medidas de NetworkManager.

m_mac_apply() {
  [[ -n $UPLINK_UUID ]] || { warn "MAC: sin conexión gestionada por NetworkManager (no aplicable)"; return 0; }
  local prop cur target
  prop=$(nm_mac_prop)
  target=$(nm_measure_target mac)
  if [[ $target == changed ]]; then m_mac_revert; fi
  cur=$(nm_get "$UPLINK_UUID" "$prop")
  if ! st_has mac.uuid; then
    st_set mac.uuid "$UPLINK_UUID" mac.prop "$prop" mac.prev "$cur"
  fi
  if [[ $cur != random ]]; then
    nm_queue "$UPLINK_UUID" 1 "$prop" random
    ok "MAC aleatoria en $UPLINK_DEV (se reconectará)"
  fi
}

m_mac_revert() {
  local uuid prop prev
  uuid=$(st_get mac.uuid 2>/dev/null || true)
  [[ -n $uuid ]] && valid_uuid "$uuid" || return 0
  prop=$(st_get mac.prop 2>/dev/null || echo 802-11-wireless.cloned-mac-address)
  prev=$(st_get mac.prev 2>/dev/null || true)
  [[ $prop =~ ^802-(11-wireless|3-ethernet)\.cloned-mac-address$ ]] || return 0
  nm_queue "$uuid" 1 "$prop" "$prev"
  st_del mac.uuid mac.prop mac.prev
}

m_mac_check() {
  [[ -n $UPLINK_DEV ]] || { echo "na|sin conexión activa"; return; }
  if ip link show dev "$UPLINK_DEV" 2>/dev/null | parse_ip_permaddr; then
    echo "ok|$UPLINK_DEV usa una MAC distinta de la de fábrica"
  else
    echo "bad|$UPLINK_DEV usa la MAC de fábrica (identificable entre redes)"
  fi
}
