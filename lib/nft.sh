# shellcheck shell=bash
# Firewall nftables propio: tabla "inet wifipublica" (IPv4 + IPv6), prioridad
# -100, independiente de ufw. Un "drop" en cualquier tabla es definitivo, así
# que convive con ufw/docker: solo puede restringir, nunca abrir.
#
# Recuperación manual siempre posible:  sudo nft delete table inet wifipublica

# Regla que permite el handshake con el servidor activo.
nft_endpoint_rule() {
  local ip=$1 port=$2 fam=ip
  is_ipv6 "$ip" && fam=ip6
  printf '%s daddr %s udp dport %s accept comment "wp-endpoint"' "$fam" "$ip" "$port"
}

# nft_build_ruleset <killswitch 0|1> <portal 0|1> <ep_ip> <ep_port> <keep_ts 0|1>
# Función pura: imprime la definición completa de la tabla.
nft_build_ruleset() {
  local ks=$1 portal=$2 ep_ip=$3 ep_port=$4 keep_ts=$5 out_policy=accept
  if (( ks || portal )); then out_policy=drop; fi
  if (( ks )) && { [[ -z $ep_ip ]] || ! is_ip "$ep_ip" || ! valid_port "$ep_port"; }; then
    echo "nft_build_ruleset: kill switch sin endpoint válido" >&2
    return 1
  fi

  cat <<EOF
table inet $NFT_TABLE {
  chain input {
    type filter hook input priority -100; policy drop;
    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    udp sport 67 udp dport 68 accept comment "dhcpv4"
    icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } ip6 hoplimit 255 accept
EOF
  if (( keep_ts )); then
    printf '    iifname "tailscale0" accept comment "tailscale"\n'
    printf '    udp dport 41641 accept comment "tailscale"\n'
  fi
  cat <<EOF
    counter comment "wp-input-drop"
  }

  chain forward {
    type filter hook forward priority -100; policy accept;
EOF
  if (( ks || portal )); then
    # Contenedores: sin salida fuera del túnel (antes de established).
    printf '    iifname "docker0" oifname != "%s" oifname != "docker0" drop comment "wp-ks-forward"\n' "$WG_IFACE"
    printf '    iifname "br-*" oifname != "%s" oifname != "br-*" drop comment "wp-ks-forward"\n' "$WG_IFACE"
  fi
  if (( keep_ts )); then
    printf '    iifname "tailscale0" accept comment "tailscale"\n'
  fi
  cat <<EOF
    ct state established,related accept
    ct status dnat ct state new drop comment "wp-docker-published"
    iifname "$WG_IFACE" ct state new drop
  }

  chain output {
    type filter hook output priority -100; policy $out_policy;
EOF
  if (( ks || portal )); then
    # Sin "established accept": las conexiones abiertas antes del kill switch
    # también se cortan si no van por el túnel.
    printf '    oifname "lo" accept\n'
    printf '    udp sport 68 udp dport 67 accept comment "dhcpv4"\n'
  fi
  if (( ks )); then
    printf '    oifname "%s" accept comment "wp-tunnel"\n' "$WG_IFACE"
    printf '    %s\n' "$(nft_endpoint_rule "$ep_ip" "$ep_port")"
  fi
  if (( portal )); then
    printf '    udp dport 53 accept comment "wp-portal"\n'
    printf '    tcp dport { 53, 80, 443 } accept comment "wp-portal"\n'
  fi
  if (( keep_ts && (ks || portal) )); then
    printf '    oifname "tailscale0" accept comment "tailscale"\n'
    printf '    udp sport 41641 accept comment "tailscale"\n'
  fi
  if (( ks || portal )); then
    printf '    counter comment "wp-output-drop"\n'
  fi
  printf '  }\n}\n'
}

# Transacción atómica: crea (si falta), borra y redefine la tabla en un solo
# "nft -f"; si algo falla, nft no aplica nada.
nft_transaction() {
  local ruleset=$1
  printf 'table inet %s\ndelete table inet %s\n%s\n' "$NFT_TABLE" "$NFT_TABLE" "$ruleset"
}

nft_table_exists() { nft list table inet "$NFT_TABLE" >/dev/null 2>&1; }

# Reconstruye la tabla a partir del estado guardado.
fw_rebuild() {
  local ks portal ep_ip ep_port keep_ts rs
  ks=$(st_get vpn.killswitch 2>/dev/null || echo 0)
  portal=$(st_get portal 2>/dev/null || echo 0)
  ep_ip=$(st_get vpn.ep_ip 2>/dev/null || true)
  ep_port=$(st_get vpn.ep_port 2>/dev/null || true)
  keep_ts=$(st_get tailscale.keep 2>/dev/null || echo 0)
  rs=$(nft_build_ruleset "$ks" "$portal" "$ep_ip" "$ep_port" "$keep_ts")
  if (( DRY_RUN )); then
    say "${C_GREY}[dry-run] nft -f - con esta tabla:${C_RESET}"
    printf '%s\n' "$rs" | sed 's/^/    /'
    return 0
  fi
  log "nft: tabla recargada (killswitch=$ks portal=$portal keep_ts=$keep_ts)"
  nft_transaction "$rs" | nft -f -
}

# Cambia SOLO la regla del endpoint (vpn use con el kill switch activo).
# Si no se encuentra, recarga la tabla completa de forma atómica.
fw_swap_endpoint() {
  local ip=$1 port=$2 handle
  if (( DRY_RUN )); then
    say "${C_GREY}[dry-run] nft replace rule inet $NFT_TABLE output handle <wp-endpoint> $(nft_endpoint_rule "$ip" "$port")${C_RESET}"
    return 0
  fi
  handle=$(nft -a list chain inet "$NFT_TABLE" output 2>/dev/null | parse_nft_handle wp-endpoint || true)
  if [[ -n $handle ]]; then
    # shellcheck disable=SC2046
    run nft replace rule inet "$NFT_TABLE" output handle "$handle" $(nft_endpoint_rule "$ip" "$port")
  else
    fw_rebuild
  fi
}

fw_delete() {
  if (( DRY_RUN )); then run nft delete table inet "$NFT_TABLE"; return 0; fi
  nft_table_exists || return 0
  run nft delete table inet "$NFT_TABLE"
}
