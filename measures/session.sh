# shellcheck shell=bash
# Medida 11: bloqueo de sesión. En Omarchy el bloqueo lo gestiona el servicio
# "idle" de omarchy-shell (no hypridle). Su IPC solo permite enable/disable,
# no cambiar el tiempo, y no se edita ~/.config/omarchy/shell.json. Por eso:
# si tienes "stay awake" activado, se desactiva durante el modo y se restaura
# en "off", y se avisa del tiempo de bloqueo real.
# Verifica la IPC disponible con:  omarchy-shell idle status

_idle_status() { as_user omarchy-shell idle status 2>/dev/null; }

m_session_apply() {
  have omarchy-shell || { warn "omarchy-shell no disponible: no se puede garantizar el bloqueo automático"; return 0; }
  local s stay lock
  s=$(_idle_status) || { warn "no se pudo consultar el bloqueo automático (¿sesión gráfica?)"; return 0; }
  stay=$(json_field stayAwake "$s" || echo false)
  lock=$(json_field lock "$s" || echo "?")
  st_has session.stay_awake || st_set session.stay_awake "$stay"
  if [[ $stay == true ]]; then
    run as_user omarchy-shell -q idle enable
    ok "bloqueo automático reactivado (tenías 'stay awake')"
  fi
  warn "la pantalla se bloquea tras ${lock}s de inactividad; no se puede acortar a 60 s sin editar shell.json (bloquea a mano con Super+Ctrl+L o 'omarchy system lock')"
}

m_session_revert() {
  if [[ $(st_get session.stay_awake 2>/dev/null || echo false) == true ]] && have omarchy-shell; then
    run as_user omarchy-shell -q idle disable || true
  fi
  st_del session.stay_awake
}

m_session_check() {
  have omarchy-shell || { echo "na|omarchy-shell no disponible"; return; }
  local s enabled lock
  s=$(_idle_status) || { echo "na|sin sesión gráfica"; return; }
  enabled=$(json_field enabled "$s" || echo false)
  lock=$(json_field lock "$s" || echo 0)
  if [[ $enabled != true ]]; then echo "bad|bloqueo automático desactivado ('stay awake')"
  elif (( lock > 300 )); then echo "warn|bloqueo tras ${lock}s"
  else echo "ok|bloqueo automático tras ${lock}s"
  fi
}
