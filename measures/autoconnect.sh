# shellcheck shell=bash
# Medida 8: desactiva (temporalmente) la autoconexión a wifis ABIERTAS
# guardadas: un "evil twin" con el mismo SSID te conectaría solo.

_open_wifis() {
  local uuid type auto name key
  while IFS= read -r line; do
    mapfile -t f < <(nm_split "$line")
    uuid=${f[0]:-} type=${f[1]:-} auto=${f[2]:-}
    name=$(IFS=:; printf '%s' "${f[*]:3}")
    [[ $type == 802-11-wireless ]] && valid_uuid "$uuid" || continue
    key=$(nm_get "$uuid" 802-11-wireless-security.key-mgmt)
    # Se reconstruye el formato que espera parse_open_autoconnect.
    printf '%s:%s:%s:%s:%s\n' "$uuid" "$type" "$auto" "$key" "${name//:/\\:}"
  done < <(nmcli -t -f UUID,TYPE,AUTOCONNECT,NAME connection show 2>/dev/null) | parse_open_autoconnect
}

m_autoconnect_apply() {
  have nmcli || { warn "falta nmcli: autoconexión no aplicable (sudo pacman -S networkmanager)"; return 0; }
  local uuid name done_uuids=() names=() prev
  prev=$(st_get autoconnect.uuids 2>/dev/null || true)
  while IFS=$'\t' read -r uuid name; do
    [[ -n $uuid ]] || continue
    run nmcli connection modify --temporary uuid "$uuid" connection.autoconnect no
    done_uuids+=("$uuid"); names+=("$name")
  done < <(_open_wifis)
  st_set autoconnect.uuids "${prev:+$prev }${done_uuids[*]}"
  if (( ${#names[@]} )); then
    warn "autoconexión desactivada en wifis abiertas guardadas: $(printf '"%s" ' "${names[@]}")"
  fi
  return 0
}

m_autoconnect_revert() {
  local uuid
  for uuid in $(st_get autoconnect.uuids 2>/dev/null || true); do
    valid_uuid "$uuid" || continue
    run nmcli connection modify --temporary uuid "$uuid" connection.autoconnect yes || true
  done
  st_del autoconnect.uuids
}

m_autoconnect_check() {
  have nmcli || { echo "na|falta nmcli"; return; }
  local n
  n=$(_open_wifis | grep -c . || true)
  if (( n > 0 )); then echo "warn|$n wifis abiertas guardadas con autoconexión"
  else echo "ok|ninguna wifi abierta se conecta sola"
  fi
}
