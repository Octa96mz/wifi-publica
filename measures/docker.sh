# shellcheck shell=bash
# Medida 2: contenedores con puertos publicados. Docker publica con DNAT y
# reglas propias, saltándose ufw. Por defecto se pausan (docker pause) y se
# reanudan en "off"; además la cadena forward del firewall bloquea cualquier
# conexión nueva a puertos publicados (ct status dnat).

_docker_public() {
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null | parse_docker_public
}

m_docker_apply() {
  have docker || { st_set docker.na 1; return 0; }
  systemctl is-active --quiet docker 2>/dev/null || return 0
  local list ids=() names=() id name ports
  list=$(_docker_public || true)
  [[ -n $list ]] || return 0
  while IFS=$'\t' read -r id name ports; do
    valid_container_id "$id" || continue
    ids+=("$id"); names+=("$name(:$ports)")
  done <<<"$list"
  (( ${#ids[@]} )) || return 0

  if (( KEEP_DOCKER )); then
    warn "Docker con puertos públicos sin pausar (--keep-docker): ${names[*]}. El firewall bloquea igualmente las conexiones entrantes."
    return 0
  fi
  if ! confirm "Contenedores con puertos públicos: ${names[*]}. ¿Pausarlos durante el modo? [S/n]" s; then
    warn "no se pausan los contenedores: ${names[*]} (el firewall los bloquea igualmente)"
    return 0
  fi
  local paused=() prev
  prev=$(st_get docker.paused 2>/dev/null || true)
  for id in "${ids[@]}"; do
    [[ " $prev " == *" $id "* ]] && continue
    if [[ $(docker inspect -f '{{.State.Paused}}' "$id" 2>/dev/null) == true ]]; then continue; fi
    run docker pause "$id" && paused+=("$id")
  done
  st_set docker.paused "${prev:+$prev }${paused[*]}"
  ok "docker: pausados ${names[*]}"
  notify normal "Docker pausado" "Pausados durante el modo: ${names[*]}"
}

m_docker_revert() {
  have docker || return 0
  local ids id
  ids=$(st_get docker.paused 2>/dev/null || true)
  for id in $ids; do
    valid_container_id "$id" || continue
    run docker unpause "$id" || warn "no se pudo reanudar el contenedor $id"
  done
  st_del docker.paused
}

m_docker_check() {
  have docker || { echo "na|Docker no instalado"; return; }
  systemctl is-active --quiet docker 2>/dev/null || { echo "ok|Docker no está en marcha"; return; }
  local list n=0 id name ports running=()
  list=$(_docker_public || true)
  while IFS=$'\t' read -r id name ports; do
    [[ -n $id ]] || continue
    [[ $(docker inspect -f '{{.State.Paused}}' "$id" 2>/dev/null) == true ]] && continue
    running+=("$name"); n=$((n + 1))
  done <<<"$list"
  if (( n == 0 )); then echo "ok|sin contenedores con puertos públicos activos"
  elif nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then echo "warn|activos con puertos públicos: ${running[*]} (bloqueados por el firewall)"
  else echo "bad|expuestos en la red: ${running[*]}"
  fi
}
