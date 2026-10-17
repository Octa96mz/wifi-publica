# shellcheck shell=bash
# Medida 9: Bluetooth no visible ni emparejable; aviso si hay compartición de
# archivos o escritorio remoto en marcha.

_bt_show() { timeout 5 bluetoothctl show 2>/dev/null; }

_sharing_warnings() {
  local p found=()
  for p in obexd wayvnc krfb rustdesk gnome-remote-desktop-daemon localsend localsend_app warpinator; do
    pgrep -x "$p" >/dev/null 2>&1 && found+=("$p")
  done
  (( ${#found[@]} )) && warn "compartición/escritorio remoto en marcha: ${found[*]} (ciérralos)"
  return 0
}

m_bluetooth_apply() {
  _sharing_warnings
  have bluetoothctl || return 0
  systemctl is-active --quiet bluetooth 2>/dev/null || return 0
  local out disc pair
  out=$(_bt_show) || return 0
  disc=$(parse_bt_flag Discoverable <<<"$out" || true)
  pair=$(parse_bt_flag Pairable <<<"$out" || true)
  [[ -n $disc ]] || return 0
  st_has bluetooth.discoverable || st_set bluetooth.discoverable "$disc" bluetooth.pairable "$pair"
  [[ $disc == yes ]] && run timeout 5 bluetoothctl discoverable off
  [[ $pair == yes ]] && run timeout 5 bluetoothctl pairable off
  ok "Bluetooth: no visible y no emparejable"
}

m_bluetooth_revert() {
  local disc pair
  disc=$(st_get bluetooth.discoverable 2>/dev/null || true)
  pair=$(st_get bluetooth.pairable 2>/dev/null || true)
  if have bluetoothctl; then
    [[ $disc == yes ]] && run timeout 5 bluetoothctl discoverable on
    [[ $pair == yes ]] && run timeout 5 bluetoothctl pairable on
  fi
  st_del bluetooth.discoverable bluetooth.pairable
  return 0
}

m_bluetooth_check() {
  have bluetoothctl || { echo "na|bluetoothctl no instalado"; return; }
  systemctl is-active --quiet bluetooth 2>/dev/null || { echo "ok|Bluetooth apagado"; return; }
  local out disc pair
  out=$(_bt_show) || { echo "na|sin controlador Bluetooth"; return; }
  disc=$(parse_bt_flag Discoverable <<<"$out" || true)
  pair=$(parse_bt_flag Pairable <<<"$out" || true)
  if [[ $disc == yes ]]; then echo "bad|Bluetooth visible para otros"
  elif [[ $pair == yes ]]; then echo "warn|no visible, pero emparejable"
  else echo "ok|no visible ni emparejable"
  fi
}
