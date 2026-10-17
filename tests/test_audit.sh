# shellcheck shell=bash
# Comprobaciones del audit con salidas REALES/simuladas:
#  - firewall: nft imprime la prioridad -100 de output como "dstnat"
#    (tests/fixtures/*.nft son listados reales de nftables 1.1.7).
#  - hostname: nmcli -g devuelve los ternarios como número (0 = no).
#  - hostname: hostnamectl --transient puede "funcionar" sin cambiar el kernel.
#  - tailscale: distinguir no aplica / bloqueado / permitido / sin bloquear.
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/nm.sh"
# shellcheck source=/dev/null
for _m in firewall hostname tailscale; do source "$ROOT/measures/$_m.sh"; done
unset _m
FX="$ROOT/tests/fixtures"
# Sin depender del equipo: ni /etc/hostname real ni hostnamed real.
# shellcheck disable=SC2034  # lo lee measures/hostname.sh
WP_ETC_HOSTNAME="$TMP/etc-hostname"
busctl() { [[ $* == *DefaultHostname* ]] && { echo 's "archlinux"'; return 0; }; return 1; }

# nft simulado: "nft list table ..." devuelve el fixture NFT_FIXTURE (o falla).
nft() {
  if [[ ${1:-} == list && -n ${NFT_FIXTURE:-} ]]; then grep -v '^#' "$NFT_FIXTURE"; return 0; fi
  return 1
}
setup_state() { WP_STATE="$TMP/state.json"; DRY_RUN=0; kv_set "$WP_STATE" vpn.killswitch "${1:-0}"; }

t_real_nft_listing_prints_output_priority_as_dstnat() {
  # Reproduce la causa del fallo: el texto literal que buscaba el audit no existe.
  grep -q 'hook output priority dstnat; policy drop;' "$FX/nft-killswitch.nft" || fail "fixture inesperado"
  ! grep -q 'hook output priority -100; policy drop' "$FX/nft-killswitch.nft" || fail "el fixture ya no reproduce el fallo"
}

t_parse_chain_policy_independent_of_priority_format() {
  assert_eq "$(parse_nft_chain_policy output <"$FX/nft-killswitch.nft")" drop
  assert_eq "$(parse_nft_chain_policy input <"$FX/nft-killswitch.nft")" drop
  assert_eq "$(parse_nft_chain_policy forward <"$FX/nft-killswitch.nft")" accept
  assert_eq "$(parse_nft_chain_policy output <"$FX/nft-sin-killswitch.nft")" accept
  # Otras formas de imprimir la prioridad, y listados con "# handle N".
  assert_eq "$(printf 'table inet t {\n\tchain output { # handle 3\n\t\ttype filter hook output priority filter - 100; policy drop;\n\t}\n}\n' | parse_nft_chain_policy output)" drop
  assert_eq "$(printf 'table inet t {\n\tchain output {\n\t\ttype filter hook output priority -100; policy accept;\n\t}\n}\n' | parse_nft_chain_policy output)" accept
  # La política de otra cadena no "se cuela".
  assert_fail parse_nft_chain_policy output < <(printf 'table inet t {\n\tchain output {\n\t}\n\tchain input {\n\t\ttype filter hook input priority 0; policy drop;\n\t}\n}\n')
}

t_firewall_check_ok_with_real_killswitch_listing() {
  setup_state 1
  NFT_FIXTURE="$FX/nft-killswitch.nft"
  local r; r=$(m_firewall_check)
  assert_eq "${r%%|*}" ok "$r"
  assert_contains "$r" "kill switch"
}

t_firewall_check_detects_real_missing_killswitch() {
  setup_state 1   # se esperaba kill switch...
  NFT_FIXTURE="$FX/nft-sin-killswitch.nft"   # ...pero la salida está en accept
  local r; r=$(m_firewall_check)
  assert_eq "${r%%|*}" bad
  assert_contains "$r" "política output: accept"
  # Salida en drop pero sin regla de endpoint.
  grep -v wp-endpoint "$FX/nft-killswitch.nft" >"$TMP/sin-endpoint.nft"
  NFT_FIXTURE="$TMP/sin-endpoint.nft"; r=$(m_firewall_check)
  assert_eq "${r%%|*}" bad
  assert_contains "$r" "sin regla de endpoint"
  # Sin kill switch esperado, el listado sin kill switch es correcto.
  setup_state 0; NFT_FIXTURE="$FX/nft-sin-killswitch.nft"
  assert_eq "$(m_firewall_check | cut -d'|' -f1)" ok
  NFT_FIXTURE=""; assert_contains "$(m_firewall_check)" "bad|tabla inet wifipublica no cargada"
}

t_hostname_check_understands_nm_ternary() {
  UPLINK_UUID=00000000-1111-2222-3333-444444444444
  WP_KERNEL_HOSTNAME="$TMP/hostname"; echo localhost >"$WP_KERNEL_HOSTNAME"
  local v
  for v in 0 no false; do
    nm_get() { printf '%s' "$MOCK_SEND"; }; MOCK_SEND=$v
    assert_eq "$(m_hostname_check | cut -d'|' -f1)" ok "dhcp-send-hostname=$v"
  done
  for v in -1 1 yes default ""; do
    MOCK_SEND=$v
    assert_eq "$(m_hostname_check | cut -d'|' -f1)" bad "dhcp-send-hostname='$v'"
  done
  # DHCP desactivado pero el kernel conserva el hostname real: aviso, no OK.
  MOCK_SEND=0; echo mi-portatil >"$WP_KERNEL_HOSTNAME"
  assert_contains "$(m_hostname_check)" "warn|no se envía por DHCP, pero el hostname del kernel sigue siendo 'mi-portatil'"
  UPLINK_UUID=""; assert_eq "$(m_hostname_check | cut -d'|' -f1)" na
}

t_hostname_apply_verifies_kernel_and_falls_back_to_sysctl() {
  WP_STATE="$TMP/st.json"; DRY_RUN=0; UPLINK_UUID=""
  WP_KERNEL_HOSTNAME="$TMP/hostname"; echo mi-portatil >"$WP_KERNEL_HOSTNAME"
  # hostnamectl "funciona" pero no cambia nada (hostname estático presente).
  hostnamectl() { return 0; }
  sysctl() { local a; for a in "$@"; do [[ $a == kernel.hostname=* ]] && printf '%s\n' "${a#kernel.hostname=}" >"$WP_KERNEL_HOSTNAME"; done; return 0; }
  local out; out=$(m_hostname_apply 2>&1)
  assert_eq "$(cat "$WP_KERNEL_HOSTNAME")" localhost "debió usar sysctl"
  assert_contains "$out" "hostname transitorio: localhost"
  # Revertir restaura el original (también vía sysctl).
  m_hostname_revert >/dev/null 2>&1
  assert_eq "$(cat "$WP_KERNEL_HOSTNAME")" mi-portatil
}

t_hostname_apply_never_claims_success_it_did_not_get() {
  WP_STATE="$TMP/st2.json"; DRY_RUN=0; UPLINK_UUID=""
  WP_KERNEL_HOSTNAME="$TMP/hostname2"; echo mi-portatil >"$WP_KERNEL_HOSTNAME"
  hostnamectl() { return 0; }
  sysctl() { return 1; }
  local out; out=$(m_hostname_apply 2>&1)
  assert_eq "$(cat "$WP_KERNEL_HOSTNAME")" mi-portatil
  assert_not_contains "$out" "hostname transitorio: localhost"
  assert_contains "$out" "no se pudo cambiar el hostname"
}

# --- Tailscale ---------------------------------------------------------------
setup_ts() {  # setup_ts <instalado 0|1> <activo 0|1>
  WP_STATE="$TMP/ts.json"; DRY_RUN=0
  WP_SYS_NET="$TMP/net"; rm -rf "$WP_SYS_NET"; mkdir -p "$WP_SYS_NET"
  TS_INSTALLED=$1
  if (( $2 )); then mkdir -p "$WP_SYS_NET/tailscale0"; TS_ACTIVE=0; else TS_ACTIVE=3; fi
  have() { if [[ $1 == tailscale ]]; then (( TS_INSTALLED )); else command -v "$1" >/dev/null 2>&1; fi; }
  systemctl() { [[ $* == *is-active*tailscaled* ]] && return "$TS_ACTIVE"; return 0; }
}

t_tailscale_not_applicable_vs_blocked_vs_allowed() {
  setup_ts 0 0; NFT_FIXTURE=""
  assert_eq "$(m_tailscale_check)" "na|Tailscale no instalado: no aplica"
  setup_ts 1 0
  assert_eq "$(m_tailscale_check)" "na|Tailscale inactivo: no aplica"
  # Activo y la tabla cargada sin reglas para tailscale0: bloqueado de verdad.
  setup_ts 1 1; NFT_FIXTURE="$FX/nft-killswitch.nft"
  assert_contains "$(m_tailscale_check)" "ok|Tailscale activo pero BLOQUEADO"
  # Activo con --keep-tailscale (listado real con iifname "tailscale0" accept).
  NFT_FIXTURE="$FX/nft-killswitch-tailscale.nft"
  assert_contains "$(m_tailscale_check)" "warn|Tailscale activo y PERMITIDO"
  # Activo y SIN firewall cargado: antes el audit decía "bloqueado" (falso).
  NFT_FIXTURE=""
  assert_contains "$(m_tailscale_check)" "bad|Tailscale activo y SIN bloquear"
}

t_parse_nft_accepts_iface() {
  assert_ok parse_nft_accepts_iface tailscale0 <"$FX/nft-killswitch-tailscale.nft"
  assert_fail parse_nft_accepts_iface tailscale0 <"$FX/nft-killswitch.nft"
  # "oifname" o un drop no cuentan como aceptar la entrada.
  assert_fail parse_nft_accepts_iface tailscale0 <<<$'\t\toifname "tailscale0" accept'
  assert_fail parse_nft_accepts_iface tailscale0 <<<$'\t\tiifname "tailscale0" drop'
}
