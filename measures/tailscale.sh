# shellcheck shell=bash
# Medida 10: Tailscale. No se toca el servicio; solo se avisa. Con el firewall
# (y sobre todo el kill switch) quedará bloqueado salvo --keep-tailscale, que
# permite tailscale0 y UDP 41641. Ojo: con kill switch, el plano de control de
# Tailscale (HTTPS a sus servidores) sigue bloqueado si no va por el túnel.

WP_SYS_NET=/sys/class/net

_ts_active() { systemctl is-active --quiet tailscaled 2>/dev/null && [[ -d $WP_SYS_NET/tailscale0 ]]; }

m_tailscale_apply() {
  st_set tailscale.keep "$KEEP_TAILSCALE"
  _ts_active || return 0
  if (( KEEP_TAILSCALE )); then
    warn "Tailscale permitido (--keep-tailscale): tailscale0 y UDP 41641 abiertos; con kill switch puede no conectar"
  else
    warn "Tailscale activo: quedará bloqueado durante el modo (usa --keep-tailscale para permitirlo)"
  fi
}

m_tailscale_revert() { st_del tailscale.keep; }

# Distingue "no aplica" (no instalado o inactivo) de "bloqueado" y "permitido"
# mirando las reglas REALMENTE cargadas, no solo el estado guardado.
m_tailscale_check() {
  local t
  have tailscale || { echo "na|Tailscale no instalado: no aplica"; return; }
  _ts_active || { echo "na|Tailscale inactivo: no aplica"; return; }
  if ! have nft || ! t=$(nft list table inet "$NFT_TABLE" 2>/dev/null); then
    echo "bad|Tailscale activo y SIN bloquear: el firewall de wifi-publica no está cargado"
    return
  fi
  if parse_nft_accepts_iface tailscale0 <<<"$t"; then
    echo "warn|Tailscale activo y PERMITIDO (--keep-tailscale): tailscale0 acepta conexiones"
  elif [[ $(parse_nft_chain_policy input <<<"$t" || true) == drop ]]; then
    echo "ok|Tailscale activo pero BLOQUEADO: tailscale0 sin reglas de entrada (política drop)"
  else
    echo "bad|Tailscale activo y la entrada del firewall no está en drop"
  fi
}
