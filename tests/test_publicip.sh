# shellcheck shell=bash
# Comprobación de la IP pública tras subir el túnel, con salidas simuladas.
# Reproduce lo visto en un equipo real: justo tras "wg-quick up" el DNS del
# túnel no responde durante unos segundos (systemd-resolved: "Using degraded
# feature set UDP instead of UDP+EDNS0 for DNS server 10.2.0.1" a los +6 s)
# y un único curl fallaba, aunque uno a mano segundos después funcionaba.
source "$ROOT/lib/vpn.sh"

# Reloj, curl, sleep y wg-quick simulados. Los contadores van en ficheros
# porque curl se ejecuta dentro de $(...).
setup_ip() {  # setup_ip <fallos antes de responder> <ip que responde>
  DRY_RUN=0
  WP_VPNSTATE="$TMP/vpn.json"; rm -f "$WP_VPNSTATE"
  CLOCK="$TMP/clock"; echo 1000 >"$CLOCK"
  CURL_LOG="$TMP/curl.log"; : >"$CURL_LOG"
  WG_LOG="$TMP/wg.log"; : >"$WG_LOG"
  SLEEPS="$TMP/sleeps"; : >"$SLEEPS"
  CURL_FAILS=$1 CURL_IP=$2
  wp_now() { cat "$CLOCK"; }
  tick() { echo $(( $(cat "$CLOCK") + $1 )) >"$CLOCK"; }
  sleep() { echo "$1" >>"$SLEEPS"; tick "${1%%.*}"; }
  curl() {
    local n t=6 a prev=""
    echo "$*" >>"$CURL_LOG"
    for a in "$@"; do [[ $prev == --max-time ]] && t=$a; prev=$a; done
    n=$(wc -l <"$CURL_LOG")
    if (( n <= CURL_FAILS )) || [[ -z $CURL_IP ]]; then
      tick "$t"   # se agota esperando al DNS
      echo "curl: (28) Resolving timed out after ${t}000 milliseconds" >&2
      return 28
    fi
    tick 0; printf '%s' "$CURL_IP"
  }
  wg-quick() { echo "$*" >>"$WG_LOG"; return 0; }
  vpn_wait_handshake() { return 0; }
}
curl_calls() { wc -l <"$CURL_LOG"; }

t_ip_retry_succeeds_after_slow_tunnel_dns() {
  setup_ip 2 203.0.113.7
  local out rc=0; out=$(vpn_up_checked 198.51.100.9 2>&1) || rc=$?
  assert_eq "$rc" 0 "$out"
  assert_eq "$(kv_get "$WP_VPNSTATE" public_ip)" 203.0.113.7
  assert_eq "$(curl_calls)" 3
  assert_not_contains "$out" "no respondió"
  assert_eq "$(cat "$WG_LOG")" "up home" "no debe bajarse el túnel"
}

t_ip_retry_exits_as_soon_as_it_answers() {
  setup_ip 0 203.0.113.7
  assert_eq "$(public_ip_via_tunnel)" 203.0.113.7
  assert_eq "$(curl_calls)" 1
  assert_eq "$(cat "$SLEEPS")" "" "no debe esperar si ya respondió"
}

t_ip_retry_gives_up_within_15s_and_keeps_tunnel() {
  setup_ip 999 ""
  local out rc=0; out=$(vpn_up_checked 198.51.100.9 2>&1) || rc=$?
  assert_eq "$rc" 0 "el handshake es la prueba principal: $out"
  assert_eq "$(cat "$WG_LOG")" "up home" "sin IP no debe bajarse el túnel"
  local elapsed=$(( $(cat "$CLOCK") - 1000 ))
  (( elapsed >= 13 && elapsed <= 15 )) || fail "plazo esperado ~15 s, fueron $elapsed s"
  (( $(curl_calls) >= 2 )) || fail "debió reintentar"
  assert_contains "$out" "túnel verificado por handshake; la IP pública no respondió en 15 s"
  assert_contains "$out" "No es un fallo de la VPN"
  assert_eq "$(kv_get "$WP_VPNSTATE" last_error)" ""
}

t_ip_retry_pauses_one_second_and_fast_failures_keep_retrying() {
  setup_ip 999 ""
  # curl que falla al instante (p. ej. "Could not resolve host").
  curl() { echo "$*" >>"$CURL_LOG"; echo "curl: (6) Could not resolve host: api.ipify.org" >&2; return 6; }
  public_ip_via_tunnel >/dev/null || true
  assert_eq "$(sort -u "$SLEEPS")" 1 "pausas de 1 s"
  (( $(curl_calls) >= 13 && $(curl_calls) <= 15 )) || fail "intentos: $(curl_calls)"
}

t_empty_ip_is_never_treated_as_unchanged() {
  setup_ip 999 ""
  local rc=0; vpn_up_checked "" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 0
  setup_ip 999 ""
  rc=0; vpn_up_checked 198.51.100.9 >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 0
  assert_not_contains "$(cat "$WG_LOG")" down
}

t_same_ip_obtained_tears_tunnel_down() {
  setup_ip 1 198.51.100.9
  local out rc=0; out=$(vpn_up_checked 198.51.100.9 2>&1) || rc=$?
  assert_eq "$rc" 1
  assert_contains "$(cat "$WG_LOG")" "down home"
  assert_contains "$out" "la IP pública no cambió (198.51.100.9)"
}

t_ip_check_after_tunnel_is_bound_to_tunnel_interface() {
  setup_ip 2 203.0.113.7
  vpn_up_checked 198.51.100.9 >/dev/null 2>&1
  local l
  while IFS= read -r l; do
    assert_contains "$l" "--interface home" "cada intento debe ir atado a 'home'"
    assert_contains "$l" "https://api.ipify.org"
  done <"$CURL_LOG"
  # Ningún intento con más de 3 s (para caber varios en el plazo).
  ! grep -qE -- '--max-time ([4-9]|[1-9][0-9])' "$CURL_LOG" || fail "intento demasiado largo: $(cat "$CURL_LOG")"
}

t_pre_tunnel_ip_is_not_bound_to_tunnel() {
  setup_ip 0 198.51.100.9
  assert_eq "$(public_ip)" 198.51.100.9
  assert_not_contains "$(cat "$CURL_LOG")" "--interface"
}

t_curl_error_text_is_never_taken_as_ip() {
  setup_ip 0 ""
  curl() { printf 'curl: (7) Failed to connect'; return 7; }
  assert_eq "$(public_ip)" ""
  _public_ip_try
  assert_eq "$PUBLIC_IP" ""
  assert_contains "$PUBLIC_IP_ERR" "Failed to connect"
}
