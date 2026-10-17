# shellcheck shell=bash
# Generador de reglas nftables (incluido el cambio de Endpoint).

t_inactive_ruleset_blocks_input_only() {
  local rs; rs=$(nft_build_ruleset 0 0 "" "" 0)
  assert_contains "$rs" "table inet wifipublica {"
  assert_contains "$(chain_of "$rs" input)" "policy drop;"
  assert_contains "$(chain_of "$rs" output)" "policy accept;"
  assert_not_contains "$rs" "wp-endpoint"
  assert_contains "$(chain_of "$rs" forward)" 'ct status dnat ct state new drop'
}

t_killswitch_allows_only_tunnel_endpoint_dhcp() {
  local rs out; rs=$(nft_build_ruleset 1 0 192.0.2.10 51820 0)
  out=$(chain_of "$rs" output)
  assert_contains "$out" "policy drop;"
  assert_contains "$out" 'oifname "lo" accept'
  assert_contains "$out" 'oifname "home" accept'
  assert_contains "$out" 'ip daddr 192.0.2.10 udp dport 51820 accept comment "wp-endpoint"'
  assert_contains "$out" 'udp sport 68 udp dport 67 accept'
  # Sin established/related en salida: las conexiones previas también se cortan.
  assert_not_contains "$out" "established"
  assert_not_contains "$out" "dport 53"
}

t_killswitch_requires_valid_endpoint() {
  assert_fail nft_build_ruleset 1 0 "" "" 0
  assert_fail nft_build_ruleset 1 0 "no-es-ip" 51820 0
  assert_fail nft_build_ruleset 1 0 192.0.2.10 70000 0
}

t_endpoint_change_only_changes_endpoint_rule() {
  local a b d
  a=$(nft_build_ruleset 1 0 192.0.2.10 51820 0)
  b=$(nft_build_ruleset 1 0 198.51.100.7 51821 0)
  d=$(diff <(echo "$a") <(echo "$b") | grep -E '^[<>]' || true)
  assert_eq "$(grep -c . <<<"$d")" 2 "líneas distintas"
  assert_contains "$(grep '^<' <<<"$d")" "ip daddr 192.0.2.10 udp dport 51820"
  assert_contains "$(grep '^>' <<<"$d")" "ip daddr 198.51.100.7 udp dport 51821"
}

t_endpoint_rule_for_swap() {
  assert_eq "$(nft_endpoint_rule 198.51.100.7 51820)" 'ip daddr 198.51.100.7 udp dport 51820 accept comment "wp-endpoint"'
  assert_eq "$(nft_endpoint_rule 2001:db8::7 51820)" 'ip6 daddr 2001:db8::7 udp dport 51820 accept comment "wp-endpoint"'
}

t_parse_handle_of_endpoint_rule() {
  local listing
  listing=$(cat <<'EOF'
table inet wifipublica {
	chain output { # handle 3
		type filter hook output priority -100; policy drop;
		oifname "lo" accept # handle 11
		oifname "home" accept comment "wp-tunnel" # handle 13
		ip daddr 192.0.2.10 udp dport 51820 accept comment "wp-endpoint" # handle 14
		counter packets 0 bytes 0 comment "wp-output-drop" # handle 15
	}
}
EOF
)
  assert_eq "$(parse_nft_handle wp-endpoint <<<"$listing")" 14
  assert_fail parse_nft_handle no-existe <<<"$listing"
}

t_portal_opens_only_dns_http_https() {
  local out; out=$(chain_of "$(nft_build_ruleset 0 1 "" "" 0)" output)
  assert_contains "$out" "policy drop;"
  assert_contains "$out" 'udp dport 53 accept'
  assert_contains "$out" 'tcp dport { 53, 80, 443 } accept'
  assert_not_contains "$out" 'oifname "home"'
}

t_keep_tailscale_opens_tailscale() {
  local rs; rs=$(nft_build_ruleset 1 0 192.0.2.10 51820 1)
  assert_contains "$(chain_of "$rs" input)" 'iifname "tailscale0" accept'
  assert_contains "$(chain_of "$rs" input)" 'udp dport 41641 accept'
  assert_contains "$(chain_of "$rs" output)" 'oifname "tailscale0" accept'
  assert_not_contains "$(nft_build_ruleset 1 0 192.0.2.10 51820 0)" tailscale0
}

t_containers_cannot_bypass_killswitch() {
  local fwd; fwd=$(chain_of "$(nft_build_ruleset 1 0 192.0.2.10 51820 0)" forward)
  assert_contains "$fwd" 'iifname "docker0" oifname != "home" oifname != "docker0" drop'
  assert_contains "$fwd" 'iifname "br-*" oifname != "home" oifname != "br-*" drop'
}

t_transaction_is_atomic_and_idempotent() {
  local tx; tx=$(nft_transaction "RULESET")
  assert_eq "$(sed -n 1p <<<"$tx")" "table inet wifipublica"
  assert_eq "$(sed -n 2p <<<"$tx")" "delete table inet wifipublica"
  assert_eq "$(sed -n 3p <<<"$tx")" "RULESET"
}
