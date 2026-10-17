# shellcheck shell=bash
# Validador y saneado de .conf de WireGuard.

t_valid_proton_conf() {
  make_conf "$TMP/a.conf"
  assert_ok wgconf_check "$TMP/a.conf"
  wgconf_check "$TMP/a.conf" >/dev/null
  assert_eq "$WGC_EP_HOST" 192.0.2.10
  assert_eq "$WGC_EP_PORT" 51820
  assert_eq "$WGC_EP_IS_IP" 1
  assert_eq "$WGC_DNS" "10.2.0.1,2001:db8::1"
}

t_crlf_conf_is_accepted() {
  make_conf "$TMP/a.conf"
  sed -i 's/$/\r/' "$TMP/a.conf"
  assert_ok wgconf_check "$TMP/a.conf"
}

t_rejects_hooks_that_run_as_root() {
  local k out
  for k in PostUp PreUp PostDown PreDown SaveConfig Table FwMark; do
    make_conf "$TMP/h.conf"
    sed -i "/^DNS/a $k = touch /tmp/pwned" "$TMP/h.conf"
    out=$(wgconf_check "$TMP/h.conf") && fail "$k aceptado"
    assert_contains "$out" "clave no permitida en [Interface]: $k"
  done
}

t_requires_dns_line() {
  make_conf "$TMP/d.conf"
  sed -i '/^DNS/d' "$TMP/d.conf"
  local out; out=$(wgconf_check "$TMP/d.conf") && fail "aceptado sin DNS"
  assert_contains "$out" "falta la línea DNS"
}

t_requires_interface_and_single_peer() {
  make_conf "$TMP/p.conf"
  sed -i '/^\[Interface\]/d' "$TMP/p.conf"
  assert_fail wgconf_check "$TMP/p.conf"
  make_conf "$TMP/p2.conf" "" "[Peer]" "PublicKey = $FAKE_PUB" "AllowedIPs = 0.0.0.0/0" "Endpoint = 192.0.2.11:51820"
  local out; out=$(wgconf_check "$TMP/p2.conf") && fail "dos peers aceptados"
  assert_contains "$out" "exactamente una sección [Peer]"
}

t_hostname_endpoint_is_detected() {
  make_conf "$TMP/n.conf"
  sed -i 's/^Endpoint = .*/Endpoint = nl-free-1.example.net:51820/' "$TMP/n.conf"
  wgconf_check "$TMP/n.conf" >/dev/null || fail "debería ser válido"
  assert_eq "$WGC_EP_IS_IP" 0
  assert_eq "$WGC_EP_HOST" nl-free-1.example.net
}

t_bad_values_rejected() {
  make_conf "$TMP/b.conf"; sed -i 's/^Endpoint = .*/Endpoint = 192.0.2.10/' "$TMP/b.conf"
  assert_fail wgconf_check "$TMP/b.conf"
  make_conf "$TMP/b.conf"; sed -i 's/^Endpoint = .*/Endpoint = 192.0.2.10:99999/' "$TMP/b.conf"
  assert_fail wgconf_check "$TMP/b.conf"
  make_conf "$TMP/b.conf"; sed -i 's/^DNS = .*/DNS = ; rm -rf \//' "$TMP/b.conf"
  assert_fail wgconf_check "$TMP/b.conf"
  make_conf "$TMP/b.conf"; sed -i 's/^PrivateKey = .*/PrivateKey = corta/' "$TMP/b.conf"
  assert_fail wgconf_check "$TMP/b.conf"
  printf '\x00\x01binario' >"$TMP/bin.conf"
  assert_fail wgconf_check "$TMP/bin.conf"
}

t_errors_never_reveal_private_key() {
  make_conf "$TMP/e.conf" "Basura = $FAKE_PRIV"
  sed -i 's/^Address = .*/Address = no-valida/' "$TMP/e.conf"
  local out; out=$(wgconf_check "$TMP/e.conf" 2>&1) && fail "debería fallar"
  assert_not_contains "$out" "$FAKE_PRIV"
  assert_not_contains "$out" "TTTTTTTT"
}

t_sanitize_keeps_only_allowed_and_rewrites_endpoint() {
  make_conf "$TMP/s.conf"
  local out; out=$(wgconf_sanitize "$TMP/s.conf" "198.51.100.7:51820")
  assert_contains "$out" "Endpoint = 198.51.100.7:51820"
  assert_not_contains "$out" "192.0.2.10"
  assert_not_contains "$out" "#"
  assert_contains "$out" "[Interface]"
  assert_contains "$out" "[Peer]"
  # El resultado saneado vuelve a ser válido.
  printf '%s\n' "$out" >"$TMP/s2.conf"
  assert_ok wgconf_check "$TMP/s2.conf"
}

t_server_names() {
  assert_eq "$(server_name_from_file /x/wg-NL-FREE-16.conf)" NL-FREE-16
  assert_eq "$(server_name_from_file 'Laptop-NL-FREE-220.conf')" Laptop-NL-FREE-220
  # Sin saneado: un nombre inválido no se "arregla", se rechaza (y se omite).
  assert_eq "$(server_name_from_file 'mi servidor (1).conf')" "mi servidor (1)"
  assert_fail valid_server_name "$(server_name_from_file 'mi servidor (1).conf')"
  assert_eq "$(server_name_from_file '/a/mis servidores vpn/wg-US-FREE-117.conf')" US-FREE-117
  assert_ok valid_server_name NL-FREE-220
  assert_fail valid_server_name "../etc/passwd"
  assert_fail valid_server_name "-rf"
  assert_fail valid_server_name "a b"
}

t_parse_endpoint_forms() {
  assert_ok parse_endpoint "[2001:db8::1]:51820"
  assert_eq "$WGC_EP_HOST" 2001:db8::1
  assert_ok parse_endpoint "host.example:443"
  assert_fail parse_endpoint "host.example"
  assert_fail parse_endpoint "a;b:51820"
}

# Regresión: los resultados deben sobrevivir a la llamada (sin subshell) y
# vpn_load_server debe exponer el endpoint del servidor guardado.
t_results_survive_call_and_load_server() {
  source "$ROOT/lib/vpn.sh"
  WG_SERVERS="$TMP/servers"; mkdir -p "$WG_SERVERS"
  make_conf "$WG_SERVERS/NL-FREE-1.conf"; chmod 600 "$WG_SERVERS/NL-FREE-1.conf"
  wgconf_check "$WG_SERVERS/NL-FREE-1.conf" >/dev/null
  assert_eq "$WGC_EP_HOST:$WGC_EP_PORT" 192.0.2.10:51820
  vpn_load_server NL-FREE-1
  assert_eq "$VPN_EP_IP $VPN_EP_PORT" "192.0.2.10 51820"
  sed -i '/^DNS/d' "$WG_SERVERS/NL-FREE-1.conf"
  assert_fail vpn_load_server NL-FREE-1
  wgconf_check "$WG_SERVERS/NL-FREE-1.conf" >/dev/null || true
  assert_contains "${WGC_ERRORS[*]}" "falta la línea DNS"
  assert_eq "$WGC_EP_HOST" ""
}
