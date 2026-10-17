# shellcheck shell=bash
# Medida 5: hostname genérico (solo transitorio) y sin enviar el hostname por
# DHCP. Se restaura al terminar. El hostname estático (/etc/hostname) no se toca.
#
# Ojo: si hay un hostname estático (tu caso: /etc/hostname), systemd-hostnamed
# no aplica el transitorio al kernel ("hostnamectl --transient" puede terminar
# bien sin cambiar nada; man hostnamectl). Por eso, con estático, se cambia
# directamente con "sysctl kernel.hostname" y se VERIFICA el hostname real.
#
# Limitaciones (comprobadas en el journal):
#  - systemd trata "localhost" como "sin definir": hostnamectl muestra entonces
#    su nombre de reserva (DefaultHostname; "archlinux" en Arch), aunque el
#    kernel valga "localhost".
#  - NetworkManager (hostname-mode=default) vuelve a imponer el hostname
#    estático ("set-hostname ... from system configuration") en eventos de red:
#    p. ej. al desaparecer la interfaz "home" en "vpn use/next". Los comandos
#    de wifi-publica lo reaplican al terminar (m_hostname_reassert); los
#    eventos ajenos (reconexión de la wifi, roaming...) no, y el audit lo
#    señala con un aviso. Sin procesos en segundo plano.

WP_KERNEL_HOSTNAME=/proc/sys/kernel/hostname
WP_ETC_HOSTNAME=/etc/hostname

_kernel_hostname() { cat "$WP_KERNEL_HOSTNAME"; }

# Hostname estático (primera línea útil de /etc/hostname) o vacío.
_static_hostname() {
  local l
  [[ -r $WP_ETC_HOSTNAME ]] || return 0
  while IFS= read -r l || [[ -n $l ]]; do
    l=${l%%#*}; l=${l//[[:space:]]/}
    [[ -n $l ]] && { printf '%s' "$l"; return 0; }
  done <"$WP_ETC_HOSTNAME"
}

# Nombre que muestra hostnamectl cuando el kernel vale "localhost".
_hostname_fallback() {
  local v=""
  have busctl && v=$(busctl get-property org.freedesktop.hostname1 /org/freedesktop/hostname1 \
    org.freedesktop.hostname1 DefaultHostname 2>/dev/null || true)
  v=${v#s \"}; v=${v%\"}
  [[ $v =~ ^[A-Za-z0-9.-]{1,64}$ ]] || v=""
  printf '%s' "${v:-su nombre de reserva}"
}

_hostname_display_note() {
  [[ $GENERIC_HOSTNAME == localhost ]] || return 0
  printf "hostnamectl puede mostrar '%s' (nombre de reserva de systemd, que trata 'localhost' como «sin definir»)" "$(_hostname_fallback)"
}

# _set_kernel_hostname <nombre>: lo cambia y lo VERIFICA. Devuelve 1 si el
# hostname del kernel no quedó con ese valor.
_set_kernel_hostname() {
  local want=$1
  (( DRY_RUN )) && { run sysctl -q -w kernel.hostname="$want"; return 0; }
  if [[ -z $(_static_hostname) ]] && have hostnamectl; then
    run hostnamectl --transient hostname "$want" >/dev/null 2>&1 || true
  fi
  [[ $(_kernel_hostname) == "$want" ]] && return 0
  run sysctl -q -w kernel.hostname="$want" >/dev/null 2>&1 || true
  [[ $(_kernel_hostname) == "$want" ]]
}

m_hostname_apply() {
  local cur
  cur=$(_kernel_hostname)
  st_has hostname.prev || st_set hostname.prev "$cur"
  if [[ $cur != "$GENERIC_HOSTNAME" ]]; then
    if _set_kernel_hostname "$GENERIC_HOSTNAME"; then
      ok "hostname transitorio: $GENERIC_HOSTNAME"
      say "  $(_hostname_display_note)"
      if [[ -n $(_static_hostname) ]]; then
        say "  NetworkManager puede restaurar '$(_static_hostname)' al reconectar: el audit lo avisa y 'on'/'vpn' lo reaplican"
      fi
    else
      warn "no se pudo cambiar el hostname a '$GENERIC_HOSTNAME' (sigue siendo '$(_kernel_hostname)'); al menos no se enviará por DHCP"
    fi
  fi

  [[ -n $UPLINK_UUID ]] || return 0
  if [[ $(nm_measure_target hostname) == changed ]]; then _hostname_revert_nm; fi
  if ! st_has hostname.uuid; then
    st_set hostname.uuid "$UPLINK_UUID" \
      hostname.v4 "$(nm_get "$UPLINK_UUID" ipv4.dhcp-send-hostname)" \
      hostname.v6 "$(nm_get "$UPLINK_UUID" ipv6.dhcp-send-hostname)"
  fi
  if ! nm_ternary_false "$(nm_get "$UPLINK_UUID" ipv4.dhcp-send-hostname)" \
    || ! nm_ternary_false "$(nm_get "$UPLINK_UUID" ipv6.dhcp-send-hostname)"; then
    nm_queue "$UPLINK_UUID" 1 ipv4.dhcp-send-hostname no ipv6.dhcp-send-hostname no
    ok "DHCP: no se enviará el hostname"
  fi
}

# m_hostname_reassert [espera_s]: si algo (NetworkManager) restauró el hostname
# mientras el modo está activo, vuelve a poner el genérico. Solo con el modo
# activo (o en portal) y la medida aplicada; NUNCA toca hostname.prev.
# <espera_s>: margen para que NetworkManager reaccione antes de comprobar
# (p. ej. tras "wg-quick down" lo hace en ~150 ms).
m_hostname_reassert() {
  local wait=${1:-0} mode cur
  (( DRY_RUN )) && return 0
  mode=$(mode_get)
  [[ $mode == active || $mode == portal ]] || return 0
  applied_has hostname && st_has hostname.prev || return 0
  (( wait > 0 )) && sleep "$wait"
  cur=$(_kernel_hostname)
  [[ $cur == "$GENERIC_HOSTNAME" ]] && return 0
  if _set_kernel_hostname "$GENERIC_HOSTNAME"; then
    ok "hostname genérico reaplicado: $GENERIC_HOSTNAME (se había restaurado '$cur', probablemente NetworkManager)"
    log "hostname reaplicado: $cur -> $GENERIC_HOSTNAME"
  else
    warn "el hostname volvió a '$cur' y no se pudo reaplicar '$GENERIC_HOSTNAME' (no se envía por DHCP)"
  fi
  return 0
}

_hostname_revert_nm() {
  local uuid v4 v6
  uuid=$(st_get hostname.uuid 2>/dev/null || true)
  [[ -n $uuid ]] && valid_uuid "$uuid" || return 0
  v4=$(st_get hostname.v4 2>/dev/null || true)
  v6=$(st_get hostname.v6 2>/dev/null || true)
  [[ $v4 =~ ^(yes|no|default|-1|0|1)?$ ]] || v4=""
  [[ $v6 =~ ^(yes|no|default|-1|0|1)?$ ]] || v6=""
  nm_queue "$uuid" 1 ipv4.dhcp-send-hostname "$v4" ipv6.dhcp-send-hostname "$v6"
  st_del hostname.uuid hostname.v4 hostname.v6
}

m_hostname_revert() {
  local prev
  prev=$(st_get hostname.prev 2>/dev/null || true)
  if [[ -n $prev && ! $prev =~ ^[A-Za-z0-9.-]{1,64}$ ]]; then
    warn "hostname previo guardado no válido; no se restaura (sigue siendo '$(_kernel_hostname)')"
  elif [[ -n $prev && $prev != "$(_kernel_hostname)" ]]; then
    _set_kernel_hostname "$prev" || warn "no se pudo restaurar el hostname '$prev' (sigue siendo '$(_kernel_hostname)')"
  fi
  st_del hostname.prev
  _hostname_revert_nm
}

# Comprueba por separado las dos cosas: envío por DHCP (lo importante: es lo
# que ve la red) y hostname REAL del kernel (OK solo si es el genérico).
m_hostname_check() {
  local h send4 send6 prev
  h=$(_kernel_hostname)
  [[ -n $UPLINK_UUID ]] || { echo "na|sin conexión activa"; return; }
  send4=$(nm_get "$UPLINK_UUID" ipv4.dhcp-send-hostname)
  send6=$(nm_get "$UPLINK_UUID" ipv6.dhcp-send-hostname)
  if ! nm_ternary_false "$send4"; then
    echo "bad|el hostname '$h' se envía por DHCP (dhcp-send-hostname=${send4:-?})"; return
  fi
  if ! nm_ternary_false "$send6"; then
    echo "bad|el hostname '$h' se envía por DHCPv6 (ipv6.dhcp-send-hostname=${send6:-?})"; return
  fi
  if [[ $h == "$GENERIC_HOSTNAME" ]]; then
    echo "ok|hostname genérico '$h' y sin envío por DHCP; $(_hostname_display_note)"
    return
  fi
  prev=$(st_get hostname.prev 2>/dev/null || true)
  if [[ -n $prev && $h == "$prev" ]] && applied_has hostname; then
    echo "warn|no se envía por DHCP, pero el hostname del kernel volvió a ser '$h': NetworkManager restaura el hostname estático en eventos de red (reconexión, cambio de interfaz). 'wifi-publica on' lo reaplica"
  else
    echo "warn|no se envía por DHCP, pero el hostname del kernel sigue siendo '$h'"
  fi
}
