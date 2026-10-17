#!/usr/bin/env bash
# Prueba de la comprobación de IP pública ("curl --interface home") DENTRO de
# un namespace de red y de montaje aislados:
#   unshare -rnm ./tests/netns-publicip.sh
# Reproduce el enrutado de wg-quick (tabla 51820 + fwmark + suppress_prefixlength)
# con interfaces dummy y cuenta, con nftables, por qué interfaz sale cada
# paquete. Comprueba, con y sin kill switch:
#  - la petición HTTPS de la comprobación sale por "home" (y solo por ahí);
#  - "--interface" no cambia la ruta del DNS (sigue el enrutado normal);
#  - si faltara el enrutado del túnel, "--interface home" sigue sin salir por
#    la wifi (sin el flag, sí saldría).
# No toca la red real: el namespace no tiene interfaces reales y el resolver
# se aísla con un /etc/nsswitch.conf y /etc/resolv.conf propios (nss-resolve,
# mdns y mymachines usan sockets unix, que atravesarían el namespace de red).
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
source lib/common.sh; source lib/parse.sh; source lib/nft.sh; source lib/state.sh
FAILS=0

[[ $(id -u) == 0 ]] || { echo "Ejecuta con: unshare -rnm $0"; exit 2; }
[[ -z $(ip -o link show | awk -F': ' '$2 != "lo"') ]] || { echo "no es un namespace de red vacío: abortado"; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'nameserver 10.2.0.1\noptions timeout:1 attempts:1\n' >"$T/resolv.conf"
printf 'hosts: files dns\n' >"$T/nsswitch.conf"
mount --bind "$T/resolv.conf" /etc/resolv.conf && mount --bind "$T/nsswitch.conf" /etc/nsswitch.conf \
  || { echo "no se pudo aislar el resolver (¿falta -m en unshare?): abortado"; exit 2; }
[[ $(grep ^hosts /etc/nsswitch.conf) == "hosts: files dns" ]] || { echo "resolver no aislado: abortado"; exit 2; }

ip link set lo up
ip link add wlan9 type dummy 2>/dev/null || { echo "sin soporte para interfaces dummy: prueba omitida"; exit 0; }
ip link set wlan9 up; ip addr add 192.0.2.2/24 dev wlan9
ip route add default dev wlan9
ip link add home type dummy; ip link set home up; ip addr add 10.2.0.2/32 dev home
wg_routes() {  # como wg-quick con AllowedIPs = 0.0.0.0/0
  ip route add default dev home table 51820
  ip rule add not fwmark 51820 table 51820
  ip rule add table main suppress_prefixlength 0
}
wg_routes_del() { ip rule del table main suppress_prefixlength 0; ip rule del not fwmark 51820 table 51820; ip route flush table 51820; }

# Contadores: "pre" (prioridad -200, antes del firewall) = interfaz elegida por
# el enrutado; "post" (prioridad 100, después) = lo que el firewall deja pasar.
nft -f - <<'EOF' || exit 1
table inet probe {
  counter pre_dns_home {}
  counter pre_dns_wlan {}
  counter pre_https_home {}
  counter pre_https_wlan {}
  counter post_dns_home {}
  counter post_dns_wlan {}
  counter post_https_home {}
  counter post_https_wlan {}
  chain pre {
    type filter hook output priority -200; policy accept;
    oifname "home" udp dport 53 counter name pre_dns_home
    oifname "wlan9" udp dport 53 counter name pre_dns_wlan
    oifname "home" tcp dport 443 counter name pre_https_home
    oifname "wlan9" tcp dport 443 counter name pre_https_wlan
  }
  chain post {
    type filter hook output priority 100; policy accept;
    oifname "home" udp dport 53 counter name post_dns_home
    oifname "wlan9" udp dport 53 counter name post_dns_wlan
    oifname "home" tcp dport 443 counter name post_https_home
    oifname "wlan9" tcp dport 443 counter name post_https_wlan
  }
}
EOF
cnt() { nft list counter inet probe "$1" | awk '/packets/ {for (i = 1; i < NF; i++) if ($i == "packets") print $(i + 1)}'; }
reset() { local c; for c in pre_dns_home pre_dns_wlan pre_https_home pre_https_wlan post_dns_home post_dns_wlan post_https_home post_https_wlan; do nft reset counter inet probe "$c" >/dev/null; done; }
# Resultado "<dns_home> <dns_wlan> <https_home> <https_wlan>" de una petición.
probe() {  # probe pre|post <args de curl...>
  local when=$1; shift
  reset
  curl -fsS --max-time 3 "$@" https://api.ipify.org >/dev/null 2>&1
  printf '%s %s %s %s' "$( (( $(cnt "${when}_dns_home") > 0 )) && echo home+ || echo home0)" \
    "$( (( $(cnt "${when}_dns_wlan") > 0 )) && echo wlan+ || echo wlan0)" \
    "$( (( $(cnt "${when}_https_home") > 0 )) && echo home+ || echo home0)" \
    "$( (( $(cnt "${when}_https_wlan") > 0 )) && echo wlan+ || echo wlan0)"
}
expect() {  # expect <esperado> <descripción> <probe args...>
  local want=$1 desc=$2 got; shift 2
  got=$(probe "$@")
  if [[ $got == "$want" ]]; then printf '  ✔ %-62s %s\n' "$desc" "$got"
  else printf '  ✗ %-62s %s (esperado %s)\n' "$desc" "$got" "$want"; FAILS=$((FAILS + 1)); fi
}
# --resolve: solo la conexión HTTPS (sin DNS). Sin él: solo DNS (el dummy no
# responde, así que curl nunca llega a conectar).
R=(--resolve api.ipify.org:443:203.0.113.5)
echo "Formato: DNS(home wlan) HTTPS(home wlan); '+' = hubo paquetes"

echo "Túnel arriba, SIN kill switch (como en 'on' antes de activarlo):"
wg_routes
expect "home0 wlan0 home+ wlan0" "HTTPS con --interface home: sale por el túnel" pre --interface home "${R[@]}"
expect "home+ wlan0 home0 wlan0" "DNS con --interface home: por el túnel (10.2.0.1)" pre --interface home
expect "home+ wlan0 home0 wlan0" "DNS sin --interface: misma ruta (el flag no la cambia)" pre

nft_transaction "$(nft_build_ruleset 1 0 192.0.2.10 51820 0)" | nft -f - || exit 1
echo "Túnel arriba, CON kill switch:"
expect "home0 wlan0 home+ wlan0" "HTTPS con --interface home: permitido" post --interface home "${R[@]}"
expect "home+ wlan0 home0 wlan0" "DNS con --interface home: permitido, por el túnel" post --interface home
expect "home+ wlan0 home0 wlan0" "DNS sin --interface: misma ruta" post

echo "Enrutado del túnel AÚN NO listo (sin reglas de wg-quick), con kill switch:"
wg_routes_del
expect "home0 wlan0 home0 wlan+" "sin --interface, la petición iría por la wifi..." pre "${R[@]}"
expect "home0 wlan0 home0 wlan0" "...y el kill switch la bloquea" post "${R[@]}"
expect "home0 wlan0 home+ wlan0" "con --interface home sale por el túnel" pre --interface home "${R[@]}"
expect "home0 wlan+ home0 wlan0" "el DNS sigue su ruta normal (el flag no la cambia)..." pre --interface home
expect "home0 wlan0 home0 wlan0" "...y el kill switch lo bloquea: nada sale por la wifi" post --interface home

nft delete table inet wifipublica
echo
(( FAILS == 0 )) && echo "IP pública por el túnel: todo correcto" || { echo "IP pública por el túnel: $FAILS fallos"; exit 1; }
