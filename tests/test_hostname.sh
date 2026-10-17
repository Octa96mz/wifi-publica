# shellcheck shell=bash
# Hostname con salidas simuladas que reproducen lo visto en un equipo real
# (journal del 17-10-2026, NetworkManager 1.58, systemd 262):
#  - hostname estático en /etc/hostname: "hostnamectl --transient" no cambia
#    el kernel; hay que usar sysctl.
#  - systemd trata "localhost" como "sin definir": hostnamectl muestra el
#    nombre de reserva (DefaultHostname = "archlinux").
#  - NetworkManager restaura el estático ("set-hostname ... from system
#    configuration") al desaparecer "home" en "vpn next".
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/nm.sh"
source "$ROOT/measures/hostname.sh"

UUID=00000000-1111-2222-3333-444444444444

# Equipo simulado: kernel, /etc/hostname, hostnamed, sysctl y nmcli.
setup_host() {  # setup_host <kernel> <estático o "">
  WP_STATE="$TMP/state.json"; rm -f "$WP_STATE"; DRY_RUN=0
  WP_KERNEL_HOSTNAME="$TMP/kernel-hostname"; echo "$1" >"$WP_KERNEL_HOSTNAME"
  WP_ETC_HOSTNAME="$TMP/etc-hostname"
  if [[ -n $2 ]]; then printf '# comentario\n%s\n' "$2" >"$WP_ETC_HOSTNAME"; else rm -f "$WP_ETC_HOSTNAME"; fi
  HNCTL_CALLS="$TMP/hostnamectl.calls"; : >"$HNCTL_CALLS"
  SLEEP_CALLS="$TMP/sleep.calls"; : >"$SLEEP_CALLS"
  # hostnamectl --transient con estático: termina bien y NO cambia el kernel.
  hostnamectl() { echo "$*" >>"$HNCTL_CALLS"; return 0; }
  sysctl() { local a; for a in "$@"; do [[ $a == kernel.hostname=* ]] && printf '%s\n' "${a#kernel.hostname=}" >"$WP_KERNEL_HOSTNAME"; done; return 0; }
  busctl() { [[ $* == *DefaultHostname* ]] && { echo 's "archlinux"'; return 0; }; return 1; }
  sleep() { echo "$*" >>"$SLEEP_CALLS"; [[ -n ${ON_SLEEP:-} ]] && eval "$ON_SLEEP"; return 0; }
  ON_SLEEP=""
  UPLINK_UUID=$UUID
  MOCK_V4=0 MOCK_V6=0
  nm_get() { case $2 in ipv4.dhcp-send-hostname) printf '%s' "$MOCK_V4" ;; ipv6.dhcp-send-hostname) printf '%s' "$MOCK_V6" ;; esac; }
  nm_queue() { :; }
}
kernel() { cat "$WP_KERNEL_HOSTNAME"; }
# Lo que hace NetworkManager: reescribe el kernel con el estático.
nm_restores_static() { echo mi-portatil >"$WP_KERNEL_HOSTNAME"; }
mode_on() { st_set mode active; applied_add hostname; }

t_static_hostname_skips_hostnamectl_and_uses_sysctl() {
  setup_host mi-portatil mi-portatil
  local out; out=$(m_hostname_apply 2>&1)
  assert_eq "$(kernel)" localhost
  assert_eq "$(cat "$HNCTL_CALLS")" "" "con estático no debe llamarse a hostnamectl --transient"
  assert_contains "$out" "hostname transitorio: localhost"
  assert_eq "$(st_get hostname.prev)" mi-portatil
}

t_apply_explains_archlinux_and_nm_limitation() {
  setup_host mi-portatil mi-portatil
  local out; out=$(m_hostname_apply 2>&1)
  assert_contains "$out" "hostnamectl puede mostrar 'archlinux'"
  assert_contains "$out" "NetworkManager puede restaurar 'mi-portatil'"
}

t_without_static_hostname_uses_hostnamectl_first() {
  setup_host mi-equipo ""
  hostnamectl() { echo "$*" >>"$HNCTL_CALLS"; [[ $* == *transient* ]] && echo "${*: -1}" >"$WP_KERNEL_HOSTNAME"; return 0; }
  sysctl() { echo "no debía usarse" >>"$HNCTL_CALLS"; return 1; }
  m_hostname_apply >/dev/null 2>&1
  assert_eq "$(kernel)" localhost
  assert_eq "$(cat "$HNCTL_CALLS")" "--transient hostname localhost"
}

t_static_hostname_that_does_not_change_warns() {
  setup_host mi-portatil mi-portatil
  sysctl() { return 0; }   # "funciona" pero el kernel no cambia
  local out; out=$(m_hostname_apply 2>&1)
  assert_eq "$(kernel)" mi-portatil
  assert_not_contains "$out" "✔ hostname transitorio"
  assert_contains "$out" "no se pudo cambiar el hostname a 'localhost' (sigue siendo 'mi-portatil')"
}

t_audit_ok_only_with_real_generic_value_and_explains_fallback() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  local r; r=$(m_hostname_check)
  assert_eq "${r%%|*}" ok "$r"
  assert_contains "$r" "hostname genérico 'localhost'"
  assert_contains "$r" "hostnamectl puede mostrar 'archlinux' (nombre de reserva de systemd"
}

t_audit_warns_when_third_party_restores_hostname_between_on_and_audit() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  assert_eq "$(m_hostname_check | cut -d'|' -f1)" ok
  nm_restores_static          # p. ej. "vpn next" o una reconexión de la wifi
  local r; r=$(m_hostname_check)
  assert_eq "${r%%|*}" warn "$r"
  assert_contains "$r" "volvió a ser 'mi-portatil'"
  assert_contains "$r" "NetworkManager restaura el hostname estático"
  assert_not_contains "$r" "archlinux"
}

t_audit_checks_dhcpv6_send_hostname_too() {
  setup_host localhost mi-portatil
  MOCK_V4=0 MOCK_V6=-1
  assert_contains "$(m_hostname_check)" "bad|el hostname 'localhost' se envía por DHCPv6"
  MOCK_V4=1 MOCK_V6=0
  assert_contains "$(m_hostname_check)" "bad|el hostname 'localhost' se envía por DHCP "
  MOCK_V4=no MOCK_V6=false
  assert_eq "$(m_hostname_check | cut -d'|' -f1)" ok
}

t_apply_disables_dhcpv6_hostname_even_if_v4_already_off() {
  setup_host mi-portatil mi-portatil
  MOCK_V4=0 MOCK_V6=-1
  NM_ARGS="$TMP/nm.args"; : >"$NM_ARGS"
  nm_queue() { echo "$*" >>"$NM_ARGS"; }
  m_hostname_apply >/dev/null 2>&1
  assert_contains "$(cat "$NM_ARGS")" "ipv6.dhcp-send-hostname no"
}

t_reassert_after_nm_restore_keeps_prev() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  nm_restores_static
  local out; out=$(m_hostname_reassert 2>&1)
  assert_eq "$(kernel)" localhost
  assert_contains "$out" "hostname genérico reaplicado: localhost (se había restaurado 'mi-portatil'"
  assert_eq "$(st_get hostname.prev)" mi-portatil "hostname.prev no debe tocarse"
  assert_eq "$(m_hostname_check | cut -d'|' -f1)" ok
}

t_reassert_only_when_mode_active_and_measure_applied() {
  setup_host mi-portatil mi-portatil
  # Inactivo: nada.
  m_hostname_reassert >/dev/null 2>&1; assert_eq "$(kernel)" mi-portatil "inactivo"
  # Activando (a medio "on"): nada; lo hará el final de "on".
  st_set mode applying hostname.prev mi-portatil; applied_add hostname
  m_hostname_reassert >/dev/null 2>&1; assert_eq "$(kernel)" mi-portatil "applying"
  # Activo pero sin la medida aplicada: nada.
  st_set mode active; applied_del hostname
  m_hostname_reassert >/dev/null 2>&1; assert_eq "$(kernel)" mi-portatil "sin medida"
  # Activo con la medida pero sin prev guardado: nada (no se podría restaurar).
  applied_add hostname; st_del hostname.prev
  m_hostname_reassert >/dev/null 2>&1; assert_eq "$(kernel)" mi-portatil "sin prev"
  # Portal (la medida sigue aplicada): sí.
  st_set mode portal hostname.prev mi-portatil
  m_hostname_reassert >/dev/null 2>&1; assert_eq "$(kernel)" localhost "portal"
  assert_eq "$(st_get hostname.prev)" mi-portatil
  # --dry-run: nunca cambia nada ni dice que lo haya hecho.
  nm_restores_static; DRY_RUN=1
  local out; out=$(m_hostname_reassert 2>&1)
  assert_eq "$(kernel)" mi-portatil "dry-run"
  assert_eq "$out" "" "dry-run"
}

t_reassert_waits_for_nm_before_checking() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  # NetworkManager restaura el estático ~150 ms DESPUÉS de "wg-quick down".
  ON_SLEEP=nm_restores_static
  m_hostname_reassert 1 >/dev/null 2>&1
  assert_eq "$(cat "$SLEEP_CALLS")" 1
  assert_eq "$(kernel)" localhost
}

t_reassert_does_not_sleep_when_not_applicable() {
  setup_host mi-portatil mi-portatil
  m_hostname_reassert 1 >/dev/null 2>&1
  assert_eq "$(cat "$SLEEP_CALLS")" "" "sin modo activo no debe esperar"
  st_set mode active   # activo, pero la medida no está aplicada
  m_hostname_reassert 1 >/dev/null 2>&1
  assert_eq "$(cat "$SLEEP_CALLS")" "" "sin la medida aplicada no debe esperar"
}

t_reassert_that_fails_warns_instead_of_claiming_success() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  nm_restores_static; sysctl() { return 0; }
  local out; out=$(m_hostname_reassert 2>&1)
  assert_not_contains "$out" "reaplicado"
  assert_contains "$out" "no se pudo reaplicar 'localhost'"
}

t_off_restores_exact_original() {
  # Original distinto del estático: debe volver exactamente ese.
  setup_host mi-equipo mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  nm_restores_static; m_hostname_reassert >/dev/null 2>&1
  assert_eq "$(kernel)" localhost
  m_hostname_revert >/dev/null 2>&1
  assert_eq "$(kernel)" mi-equipo
  assert_fail st_has hostname.prev
  # Caso habitual: NetworkManager ya lo había restaurado; "off" no lo cambia.
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1; nm_restores_static
  sysctl() { echo "no debía llamarse" >"$WP_KERNEL_HOSTNAME"; }
  m_hostname_revert >/dev/null 2>&1
  assert_eq "$(kernel)" mi-portatil
}

t_second_on_does_not_overwrite_prev() {
  setup_host mi-portatil mi-portatil; mode_on
  m_hostname_apply >/dev/null 2>&1
  echo otro-nombre >"$WP_KERNEL_HOSTNAME"   # algo lo cambió durante el modo
  m_hostname_apply >/dev/null 2>&1
  assert_eq "$(st_get hostname.prev)" mi-portatil
  m_hostname_revert >/dev/null 2>&1
  assert_eq "$(kernel)" mi-portatil
}

t_invalid_saved_prev_is_reported() {
  setup_host localhost mi-portatil
  st_set hostname.prev 'mal nombre;rm'
  local out; out=$(m_hostname_revert 2>&1)
  assert_contains "$out" "hostname previo guardado no válido"
  assert_eq "$(kernel)" localhost
}

# Contrato: los comandos que provocan que NetworkManager restaure el hostname
# lo reaplican al terminar (la barra usa estos mismos comandos).
t_commands_that_trigger_nm_reassert_hostname() {
  local f
  for f in cmd_on cmd_portal cmd_vpn_on cmd_vpn_off cmd_vpn_use; do
    awk -v f="$f() {" '$0 == f {p=1} p {print} p && /^}/ {exit}' "$ROOT/bin/wifi-publica" | grep -q 'm_hostname_reassert' \
      || fail "$f no reaplica el hostname"
  done
  # vpn use: tanto al cambiar con éxito como en la vuelta atrás.
  local body; body=$(awk '$0 == "cmd_vpn_use() {" {p=1} p {print} p && /^}/ {exit}' "$ROOT/bin/wifi-publica")
  awk '/if vpn_up_checked "\$pre"; then/ {p=1} p {print} p && /return 0/ {exit}' <<<"$body" | grep -q m_hostname_reassert \
    || fail "cmd_vpn_use no reaplica el hostname tras cambiar de servidor"
  awk '/# 7. Vuelta atrás/ {p=1} p {print}' <<<"$body" | grep -q m_hostname_reassert \
    || fail "cmd_vpn_use no reaplica el hostname tras la vuelta atrás"
  # vpn next/prev pasan por cmd_vpn_use.
  awk '$0 == "cmd_vpn_cycle() {" {p=1} p {print} p && /^}/ {exit}' "$ROOT/bin/wifi-publica" | grep -q 'cmd_vpn_use' \
    || fail "cmd_vpn_cycle ya no pasa por cmd_vpn_use"
  # vpn off y portal esperan a que NetworkManager reaccione.
  awk '$0 == "cmd_vpn_off() {" {p=1} p {print} p && /^}/ {exit}' "$ROOT/bin/wifi-publica" | grep -q 'm_hostname_reassert 1' \
    || fail "cmd_vpn_off no espera a NetworkManager"
}
