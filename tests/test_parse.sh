# shellcheck shell=bash
# Parseo de salidas simuladas de ss, docker, nmcli, wg, bluetoothctl,
# resolvectl, ip y del estado JSON.

t_ss_listeners_exclude_loopback_and_multicast() {
  local out
  out=$(parse_ss_listeners <<'EOF'
udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=1))
udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("avahi-daemon",pid=2,fd=12))
udp UNCONN 0 0 224.0.0.251:5353 0.0.0.0:* users:(("brave",pid=3,fd=40))
tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=4,fd=3))
tcp LISTEN 0 128 [::1]:631 [::]:* users:(("cupsd",pid=5,fd=7))
tcp LISTEN 0 128 127.0.0.1:631 0.0.0.0:* users:(("cupsd",pid=5,fd=8))
tcp LISTEN 0 4096 [::]:8000 [::]:*
tcp LISTEN 0 4096 100.64.0.1%tailscale0:3000 0.0.0.0:*
EOF
)
  assert_eq "$(grep -c . <<<"$out")" 3
  assert_contains "$out" "udp 0.0.0.0:5353 avahi-daemon"
  assert_contains "$out" "tcp 0.0.0.0:22 sshd"
  assert_contains "$out" "tcp [::]:8000 -"
  assert_not_contains "$out" cupsd
  assert_not_contains "$out" brave
}

t_docker_public_ports() {
  local out
  out=$(parse_docker_public <<'EOF'
aaaaaaaaaaaa	webapp	0.0.0.0:8000->8000/tcp, [::]:8000->8000/tcp
5b11aa22cc33	webapp_db	5432/tcp
6c22bb33dd44	local_only	127.0.0.1:8080->80/tcp
bbbbbbbbbbbb	proxy	0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, [::]:443->443/tcp, 443/udp, 2019/tcp
EOF
)
  assert_eq "$(grep -c . <<<"$out")" 2
  assert_contains "$out" $'aaaaaaaaaaaa\twebapp\t8000'
  assert_contains "$out" $'bbbbbbbbbbbb\tproxy\t80,443'
  assert_not_contains "$out" local_only
}

t_nm_split_handles_escaped_colons() {
  local -a f
  mapfile -t f < <(nm_split 'uuid-1:802-11-wireless:yes::Café\: Free WiFi')
  assert_eq "${#f[@]}" 5
  assert_eq "${f[4]}" "Café: Free WiFi"
  assert_eq "$(nm_unescape 'fe80\:\:1')" "fe80::1"
}

t_uplink_prefers_wifi() {
  local out
  out=$(parse_uplink <<'EOF'
docker0:bridge:connected (externally)
enp0s20f0u1:ethernet:connected
wlan0:wifi:connected
lo:loopback:connected (externally)
EOF
)
  assert_eq "$out" "wlan0 wifi"
  out=$(printf 'enp0s20f0u1:ethernet:connected\nwlan0:wifi:disconnected\n' | parse_uplink)
  assert_eq "$out" "enp0s20f0u1 ethernet"
  assert_fail parse_uplink <<<"wlan0:wifi:disconnected"
}

t_active_uuid_of_device() {
  local out
  out=$(parse_active_uuid wlan0 <<'EOF'
11111111-2222-4333-8444-555555555555:tailscale0
00000000-1111-2222-3333-444444444444:wlan0
EOF
)
  assert_eq "$out" 00000000-1111-2222-3333-444444444444
}

t_open_wifis_with_autoconnect() {
  local out
  out=$(parse_open_autoconnect <<'EOF'
aaaaaaaa-0000-0000-0000-000000000001:802-11-wireless:yes::Aeropuerto Free
aaaaaaaa-0000-0000-0000-000000000002:802-11-wireless:yes:wpa-psk:Casa
aaaaaaaa-0000-0000-0000-000000000003:802-11-wireless:no::Hotel
aaaaaaaa-0000-0000-0000-000000000004:802-3-ethernet:yes::Cable
aaaaaaaa-0000-0000-0000-000000000005:802-11-wireless:yes::Bar\: Wifi
EOF
)
  assert_eq "$(grep -c . <<<"$out")" 2
  assert_contains "$out" $'aaaaaaaa-0000-0000-0000-000000000001\tAeropuerto Free'
  assert_contains "$out" $'aaaaaaaa-0000-0000-0000-000000000005\tBar: Wifi'
}

t_bluetooth_flags() {
  local show
  show=$(cat <<'EOF'
Controller 00:11:22:33:44:55 (public)
	Name: laptop
	Powered: yes
	Discoverable: yes
	Pairable: no
EOF
)
  assert_eq "$(parse_bt_flag Discoverable <<<"$show")" yes
  assert_eq "$(parse_bt_flag Pairable <<<"$show")" no
  assert_fail parse_bt_flag Discoverable <<<"No default controller available"
}

t_wg_show_handshake_and_transfer() {
  assert_eq "$(printf 'PUBKEY=\t1791800000\n' | parse_wg_handshake)" 1791800000
  assert_eq "$(printf 'PUBKEY=\t0\n' | parse_wg_handshake)" 0
  assert_eq "$(printf '' | parse_wg_handshake)" 0
  assert_eq "$(printf 'A=\t1000\t200\nB=\t24\t56\n' | parse_wg_transfer)" "1024 256"
}

t_resolvectl_values() {
  assert_eq "$(parse_resolvectl_value 'Link 3 (wlan0): 9.9.9.9#dns.quad9.net 1.1.1.1')" "9.9.9.9#dns.quad9.net 1.1.1.1"
  assert_eq "$(parse_resolvectl_value 'Link 7 (home): yes')" yes
  assert_eq "$(parse_resolvectl_value 'Link 7 (home):')" ""
  assert_eq "$(parse_resolvectl_value 'Global: no')" no
}

t_ip_permaddr_detects_random_mac() {
  assert_ok parse_ip_permaddr <<<"3: wlan0: <UP> mtu 1500
    link/ether 2a:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff permaddr 00:11:22:33:44:55"
  assert_fail parse_ip_permaddr <<<"    link/ether 00:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff"
}

t_idle_ipc_json_fields() {
  local j='{"enabled":false,"stayAwake":true,"lock":300,"screensaver":150}'
  assert_eq "$(json_field stayAwake "$j")" true
  assert_eq "$(json_field enabled "$j")" false
  assert_eq "$(json_field lock "$j")" 300
}

t_state_roundtrip_and_escaping() {
  DRY_RUN=0
  local sf="$TMP/state.json"
  kv_set "$sf" mode active weird 'a "quoted" \ back\slash' empty ""
  assert_eq "$(kv_get "$sf" mode)" active
  assert_eq "$(kv_get "$sf" weird)" 'a "quoted" \ back\slash'
  assert_eq "$(kv_get "$sf" empty)" ""
  kv_set "$sf" mode portal
  assert_eq "$(kv_get "$sf" mode)" portal
  kv_del "$sf" weird
  assert_fail kv_get "$sf" weird
  assert_ok python3 -c "import json,sys; json.load(open('$sf'))"
}

t_applied_list_operations() {
  # shellcheck disable=SC2034  # los leen las funciones de lib/state.sh
  DRY_RUN=0 WP_STATE="$TMP/st.json"
  applied_add firewall; applied_add dns; applied_add firewall
  assert_eq "$(applied_list)" "firewall dns"
  assert_eq "$(applied_count)" 2
  applied_del firewall
  assert_eq "$(applied_list)" dns
}

t_input_validation() {
  assert_ok is_ipv4 203.0.113.20
  assert_fail is_ipv4 256.1.1.1
  assert_fail is_ipv4 "1.2.3.4;id"
  assert_ok is_ipv6 2001:db8::2:1
  assert_ok valid_port 51820
  assert_fail valid_port 0
  assert_fail valid_port 65536
  assert_ok valid_uuid 12345678-9abc-4def-8123-456789abcdef
  assert_fail valid_uuid "x; rm -rf /"
  assert_fail valid_container_id "abc"
}
