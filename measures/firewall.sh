# shellcheck shell=bash
# Medida 1: firewall nftables propio (tabla inet wifipublica, entrada drop).

m_firewall_apply() {
  need_cmd nft nftables || { st_set firewall.na 1; return 0; }
  fw_rebuild
  ok "firewall: tabla inet $NFT_TABLE (entrada drop, IPv4+IPv6, puertos Docker bloqueados)"
}

m_firewall_revert() {
  have nft || return 0
  fw_delete
}

# Lee la política de cada cadena con parse_nft_chain_policy: nft muestra la
# prioridad -100 de output como "dstnat", así que no se compara texto literal.
m_firewall_check() {
  have nft || { echo "na|falta nft (sudo pacman -S nftables)"; return; }
  local t in_pol out_pol
  t=$(nft list table inet "$NFT_TABLE" 2>/dev/null) || { echo "bad|tabla inet $NFT_TABLE no cargada"; return; }
  in_pol=$(parse_nft_chain_policy input <<<"$t" || true)
  out_pol=$(parse_nft_chain_policy output <<<"$t" || true)
  if [[ $in_pol != drop ]]; then
    echo "bad|la cadena input no tiene política drop (política: ${in_pol:-desconocida})"; return
  fi
  if [[ $(st_get vpn.killswitch 2>/dev/null || echo 0) == 1 ]]; then
    if [[ $out_pol != drop ]]; then
      echo "bad|kill switch esperado pero la salida no está bloqueada (política output: ${out_pol:-desconocida})"; return
    fi
    if ! grep -q 'comment "wp-endpoint"' <<<"$t"; then
      echo "bad|kill switch sin regla de endpoint: la VPN no podría hacer handshake"; return
    fi
    echo "ok|entrada drop + kill switch en la salida (solo túnel y endpoint)"
  else
    echo "ok|entrada drop (IPv4+IPv6), puertos publicados por Docker bloqueados"
  fi
}
