#!/usr/bin/env bash
# Prueba funcional del kill switch DENTRO de un namespace de red aislado:
#   unshare -rn ./tests/netns-killswitch.sh
# Crea interfaces dummy "wlan9" y "home", carga la tabla generada por
# nft_build_ruleset y comprueba qué tráfico puede salir. No requiere root
# (usa un user namespace) y no toca la red real del equipo.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source lib/common.sh; source lib/parse.sh; source lib/nft.sh; source lib/state.sh
source measures/firewall.sh
FAILS=0

send() { timeout 2 bash -c "echo x >/dev/$1/$2/$3" 2>/dev/null && echo PERMITIDO || echo BLOQUEADO; }
expect() { # esperado proto ip puerto descripción
  local got; got=$(send "$2" "$3" "$4")
  if [[ $got == "$1" ]]; then printf '  ✔ %-48s %s\n' "$5" "$got"
  else printf '  ✗ %-48s %s (esperado %s)\n' "$5" "$got" "$1"; FAILS=$((FAILS + 1)); fi
}

[[ $(id -u) == 0 ]] || { echo "Ejecuta con: unshare -rn $0"; exit 2; }
ip link add wlan9 type dummy 2>/dev/null || { echo "sin soporte para interfaces dummy: prueba omitida"; exit 0; }
ip link set lo up; ip link set wlan9 up; ip addr add 192.0.2.2/24 dev wlan9
ip link add home type dummy; ip link set home up; ip addr add 10.2.0.2/32 dev home
ip route add default dev wlan9
ip route add 198.51.100.0/24 dev home

echo "Sin kill switch:"
expect PERMITIDO udp 192.0.2.99 53 "DNS por la wifi"

nft_transaction "$(nft_build_ruleset 1 0 192.0.2.10 51820 0)" | nft -f - || exit 1
echo "Con kill switch (endpoint 192.0.2.10:51820):"
expect BLOQUEADO udp 192.0.2.99 53 "DNS fuera del túnel"
expect PERMITIDO udp 192.0.2.10 51820 "handshake con el endpoint"
expect BLOQUEADO udp 192.0.2.10 53 "endpoint, otro puerto"
expect PERMITIDO udp 198.51.100.1 53 "tráfico por la interfaz 'home'"
expect PERMITIDO udp 127.0.0.1 53 "loopback"

# El audit debe leer bien el listado REAL de esta versión de nft (que muestra
# la prioridad -100 de output como "dstnat").
WP_STATE=$(mktemp); DRY_RUN=0; kv_set "$WP_STATE" vpn.killswitch 1
res=$(m_firewall_check)
if [[ ${res%%|*} == ok ]]; then printf '  ✔ %-48s %s\n' "audit del firewall sobre la tabla real" OK
else printf '  ✗ %-48s %s\n' "audit del firewall sobre la tabla real" "$res"; FAILS=$((FAILS + 1)); fi
rm -f "$WP_STATE"

H=$(nft -a list chain inet wifipublica output | parse_nft_handle wp-endpoint)
# shellcheck disable=SC2046
nft replace rule inet wifipublica output handle "$H" $(nft_endpoint_rule 192.0.2.20 51821)
echo "Tras 'vpn use' (endpoint → 192.0.2.20:51821, solo se cambia esa regla):"
expect BLOQUEADO udp 192.0.2.10 51820 "endpoint anterior"
expect PERMITIDO udp 192.0.2.20 51821 "endpoint nuevo"

nft delete table inet wifipublica
echo "Tras 'nft delete table inet wifipublica':"
expect PERMITIDO udp 192.0.2.99 53 "red restaurada"

echo
(( FAILS == 0 )) && echo "Kill switch: todo correcto" || { echo "Kill switch: $FAILS fallos"; exit 1; }
