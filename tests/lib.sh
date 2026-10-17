# shellcheck shell=bash
# Utilidades de test y carga de las librerías del proyecto (solo funciones).
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
for _f in common state parse wgconf nft; do
  # shellcheck source=/dev/null
  source "$ROOT/lib/$_f.sh"
done
unset _f
# shellcheck disable=SC2034  # anula los colores de lib/common.sh
C_RED="" C_GREEN="" C_YELLOW="" C_GREY="" C_BOLD="" C_RESET=""

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Claves FALSAS con formato válido de WireGuard (nunca claves reales).
FAKE_PRIV="$(printf 'T%.0s' {1..42})A="
FAKE_PUB="$(printf 'P%.0s' {1..42})E="

fail() { echo "FALLO: $*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "${3:-} esperado [$2], obtenido [$1]"; }
assert_contains() { [[ $1 == *"$2"* ]] || fail "${3:-} no contiene [$2] en: $1"; }
assert_not_contains() { [[ $1 != *"$2"* ]] || fail "${3:-} contiene [$2]"; }
assert_ok() { "$@" >/dev/null 2>&1 || fail "debería tener éxito: $*"; }
assert_fail() { ! "$@" >/dev/null 2>&1 || fail "debería fallar: $*"; }

# Cadena "chain <nombre> { ... }" de un ruleset.
chain_of() { awk -v c="chain $2 {" '$0 ~ c {f=1} f {print} f && /^  }/ {exit}' <<<"$1"; }

# .conf de ejemplo (formato Proton, IPs de documentación RFC 5737/3849).
make_conf() {
  local f=$1; shift
  cat >"$f" <<EOF
[Interface]
# Key for test
PrivateKey = $FAKE_PRIV
Address = 10.2.0.2/32, 2001:db8::2/128
DNS = 10.2.0.1, 2001:db8::1

[Peer]
# TEST-FREE#1
PublicKey = $FAKE_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.10:51820
PersistentKeepalive = 25
EOF
  local extra
  for extra in "$@"; do printf '%s\n' "$extra" >>"$f"; done
}
