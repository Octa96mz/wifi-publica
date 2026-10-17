# shellcheck shell=bash
# NetworkManager: todos los cambios usan `nmcli connection modify --temporary`
# (solo en memoria, NUNCA se escriben en /etc/NetworkManager). Se acumulan en
# una cola y se aplican de una vez para reconectar como mucho una vez.
#
# Aviso: si mientras el modo está activo guardas el perfil desde una GUI, los
# valores temporales se harían permanentes. Desactiva el modo antes.

UPLINK_DEV="" UPLINK_TYPE="" UPLINK_UUID=""
NM_Q=() NM_Q_UUID="" NM_Q_RECONNECT=0

# Detecta la conexión de subida (wifi preferida, si no ethernet, p. ej. USB
# tethering del iPhone). Devuelve 1 si NetworkManager no gestiona ninguna.
nm_detect_uplink() {
  local r
  UPLINK_DEV="" UPLINK_TYPE="" UPLINK_UUID=""
  have nmcli || return 1
  r=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | parse_uplink) || return 1
  UPLINK_DEV=${r% *} UPLINK_TYPE=${r#* }
  valid_iface "$UPLINK_DEV" || return 1
  UPLINK_UUID=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | parse_active_uuid "$UPLINK_DEV") || return 1
  valid_uuid "$UPLINK_UUID"
}

nm_get() { nm_unescape "$(nmcli -g "$2" connection show "$1" 2>/dev/null || true)"; }

nm_mac_prop() {
  if [[ $UPLINK_TYPE == wifi ]]; then printf '802-11-wireless.cloned-mac-address'
  else printf '802-3-ethernet.cloned-mac-address'; fi
}

# nm_queue <uuid> <reconectar 0|1> <propiedad> <valor> [<propiedad> <valor>...]
nm_queue() {
  local uuid=$1 rc=$2; shift 2
  if [[ -n $NM_Q_UUID && $NM_Q_UUID != "$uuid" ]]; then nm_commit; fi
  NM_Q_UUID=$uuid
  NM_Q+=("$@")
  (( rc )) && NM_Q_RECONNECT=1
  return 0
}

# Aplica la cola: una modificación temporal y, si hace falta, una reconexión
# (MAC y envío de hostname por DHCP solo cambian al reconectar).
nm_commit() {
  (( ${#NM_Q[@]} )) || return 0
  local uuid=$NM_Q_UUID rc=$NM_Q_RECONNECT dev
  run nmcli connection modify --temporary uuid "$uuid" "${NM_Q[@]}"
  if (( rc )); then
    run nmcli --wait 30 connection up uuid "$uuid"
  else
    dev=$(nmcli -g GENERAL.DEVICES connection show uuid "$uuid" 2>/dev/null || true)
    if [[ -n $dev ]] && valid_iface "$dev"; then
      run nmcli device reapply "$dev" || run nmcli --wait 30 connection up uuid "$uuid"
    fi
  fi
  NM_Q=() NM_Q_UUID="" NM_Q_RECONNECT=0
}

# Comprueba si la conexión activa es la misma sobre la que se aplicó la medida.
nm_measure_target() {
  local m=$1 saved
  saved=$(st_get "$m.uuid" 2>/dev/null || true)
  if [[ -n $saved && $saved != "$UPLINK_UUID" ]]; then
    printf 'changed'
  elif [[ -n $saved ]]; then
    printf 'same'
  else
    printf 'new'
  fi
}
