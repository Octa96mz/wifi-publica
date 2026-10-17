# shellcheck shell=bash
# Medida 3: servicios que escuchan en la red. Se detienen (systemctl stop,
# nunca disable) y se vuelven a arrancar en "off".

WP_SYSTEM_UNITS=(
  sshd.service
  avahi-daemon.socket avahi-daemon.service
  cups.path cups.socket cups.service
  smb.service nmb.service samba.service
  wsdd.service wsdd2.service
)
WP_USER_UNITS=(syncthing.service)

_services_user_ctl() {
  local u; u=$(wp_user) || return 1
  systemctl --user --machine="$u@.host" "$@"
}

m_services_apply() {
  local stopped=() u prev line listeners=()
  prev=$(st_get services.stopped 2>/dev/null || true)
  local all=("${WP_SYSTEM_UNITS[@]}")
  if u=$(wp_user); then all+=("syncthing@$u.service"); fi
  for u in "${all[@]}"; do
    [[ " $prev " == *" $u "* ]] && continue
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      run systemctl stop "$u" && stopped+=("$u")
    fi
  done
  for u in "${WP_USER_UNITS[@]}"; do
    [[ " $prev " == *" user:$u "* ]] && continue
    if _services_user_ctl is-active --quiet "$u" 2>/dev/null; then
      run _services_user_ctl stop "$u" && stopped+=("user:$u")
    fi
  done
  st_set services.stopped "${prev:+$prev }${stopped[*]}"
  (( ${#stopped[@]} )) && ok "servicios detenidos: ${stopped[*]}"

  if pgrep -x kdeconnectd >/dev/null 2>&1; then
    warn "KDE Connect está en marcha: ciérralo (el firewall lo bloquea igualmente)"
  fi
  if have ss; then
    while IFS= read -r line; do
      [[ -n $line ]] && listeners+=("$line")
    done < <(ss -H -tulpn 2>/dev/null | parse_ss_listeners | grep -vE ' (docker-proxy|tailscaled|systemd-resolve|NetworkManager|dhcpcd)$' | sort -u || true)
    if (( ${#listeners[@]} )); then
      warn "siguen escuchando fuera de loopback (bloqueados por el firewall): $(printf '%s; ' "${listeners[@]}")"
    fi
  fi
  return 0
}

m_services_revert() {
  local list u i
  list=$(st_get services.stopped 2>/dev/null || true)
  read -r -a arr <<<"$list"
  for (( i = ${#arr[@]} - 1; i >= 0; i-- )); do
    u=${arr[i]}
    if [[ $u == user:* ]]; then
      run _services_user_ctl start "${u#user:}" || warn "no se pudo arrancar ${u#user:}"
    else
      [[ $u =~ ^[A-Za-z0-9@._-]+$ ]] || continue
      run systemctl start "$u" || warn "no se pudo arrancar $u"
    fi
  done
  st_del services.stopped
}

m_services_check() {
  local active=() u n=0
  for u in "${WP_SYSTEM_UNITS[@]}"; do
    systemctl is-active --quiet "$u" 2>/dev/null && active+=("$u")
  done
  if have ss; then
    n=$(ss -H -tulpn 2>/dev/null | parse_ss_listeners | grep -cvE ' (docker-proxy|tailscaled|systemd-resolve|NetworkManager|dhcpcd)$' || true)
  fi
  if (( ${#active[@]} )); then echo "bad|activos: ${active[*]}"
  elif (( n > 0 )); then echo "warn|$n sockets escuchan fuera de loopback (bloqueados por el firewall si está activo)"
  else echo "ok|ningún servicio de red expuesto"
  fi
}
