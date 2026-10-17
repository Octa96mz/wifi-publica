# shellcheck shell=bash
# Separación de privilegios: "vpn import" solo es alcanzable por el
# ejecutable con contraseña; el de la regla NOPASSWD no puede importar ni
# activar ficheros que no sean servidores ya importados.
source "$ROOT/lib/cli.sh"
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/sudoers.sh"

# Simula exactamente lo que hace bin/wifi-publica como root con sus argumentos.
route_of() { parse_args "$@"; route_root "${POS[@]}"; }

t_root_route_never_imports() {
  local args r
  local -a cases=(
    "vpn import /tmp/x.conf"
    "vpn import /tmp/x.conf NOMBRE"
    "vpn import"
    "--yes vpn import /tmp/x.conf"
    "--dry-run --yes vpn import /tmp/x.conf"
    "-- vpn import /tmp/x.conf"
    "vpn -- import /tmp/x.conf"
    "vpn IMPORT /tmp/x.conf"
    "vpn Import /tmp/x.conf"
    "VPN import /tmp/x.conf"
    "vpn ./import /tmp/x.conf"
    "vpn import=x"
    "vpn imp0rt /tmp/x.conf"
    "vpn use import"
    "vpn use import /tmp/x.conf"
  )
  for args in "${cases[@]}"; do
    # shellcheck disable=SC2086
    r=$(route_of $args)
    [[ $r == reject:* || $r == vpn_use ]] || fail "'$args' → $r"
    [[ $r != *import* || $r == reject:* ]] || fail "'$args' → $r"
  done
  # "vpn use import" es un nombre de servidor (válido) que no existirá:
  assert_eq "$(route_of vpn use import)" vpn_use
  assert_eq "$(route_of vpn use import /tmp/x.conf)" "reject:comando no válido"
}

t_root_route_rejects_paths_case_and_extra_args() {
  assert_eq "$(route_of vpn use ../../etc/shadow)" "reject:nombre de servidor no válido"
  assert_eq "$(route_of vpn use /tmp/evil.conf)" "reject:nombre de servidor no válido"
  assert_eq "$(route_of vpn use servers/NL)" "reject:nombre de servidor no válido"
  assert_eq "$(route_of vpn use .hidden)" "reject:nombre de servidor no válido"
  assert_eq "$(route_of vpn use 'a b')" "reject:nombre de servidor no válido"
  assert_eq "$(route_of ON)" "reject:comando no válido"
  assert_eq "$(route_of vpn ON)" "reject:comando no válido"
  assert_eq "$(route_of on extra)" "reject:comando no válido"
  assert_eq "$(route_of vpn next extra)" "reject:comando no válido"
  assert_eq "$(route_of vpn use a b)" "reject:comando no válido"
}

t_root_route_normal_commands() {
  assert_eq "$(route_of on)" on
  assert_eq "$(route_of --keep-docker on)" on
  assert_eq "$(route_of off)" off
  assert_eq "$(route_of portal --seconds 60)" portal
  assert_eq "$(route_of vpn toggle)" vpn_toggle
  assert_eq "$(route_of --yes vpn off)" vpn_off
  assert_eq "$(route_of vpn use NL-FREE-16)" vpn_use
  assert_eq "$(route_of vpn next)" vpn_next
  assert_eq "$(route_of vpn _probe)" vpn__probe
}

# Comprobación estática: el ejecutable NOPASSWD no carga ni define el código
# de importación; el de importación no despacha otros comandos.
t_nopasswd_binary_has_no_import_code() {
  local main="$ROOT/bin/wifi-publica" imp="$ROOT/bin/wifi-publica-import"
  ! grep -qE 'import\.sh|for _f in .*\bimport\b|cmd_vpn_import' "$main" || fail "bin/wifi-publica carga o usa el código de importación"
  grep -qE '^for _f in .*\bimport\b' "$imp" || fail "wifi-publica-import no carga lib/import.sh"
  ! grep -qE 'cmd_(on|off|portal|vpn_use|vpn_on)\b|route_root' "$imp" || fail "wifi-publica-import despacha otros comandos"
  grep -q 'cmd_vpn_import()' "$ROOT/lib/import.sh" || fail "falta cmd_vpn_import en lib/import.sh"
}

t_import_args_are_strict() {
  assert_ok parse_import_args /tmp/a.conf
  assert_eq "${IMPORT_FILES[*]}|$IMPORT_NAME" "/tmp/a.conf|"
  assert_ok parse_import_args --yes -- /tmp/a.conf NL-FREE-1
  assert_eq "${IMPORT_FILES[*]}|$IMPORT_NAME" "/tmp/a.conf|NL-FREE-1"
  assert_ok parse_import_args --dry-run "/x/mis servidores vpn/a.conf" b.conf
  assert_eq "${#IMPORT_FILES[@]}|${IMPORT_FILES[0]}|$IMPORT_NAME" "2|/x/mis servidores vpn/a.conf|"
  assert_fail parse_import_args
  assert_fail parse_import_args /tmp/a.conf NOMBRE extra
  assert_fail parse_import_args /tmp/a.conf /tmp/b.conf NOMBRE
  assert_fail parse_import_args vpn use NL-FREE-1
  assert_fail parse_import_args --keep-docker /tmp/a.conf
  assert_fail parse_import_args /tmp/a.conf ../../etc/x
  assert_fail parse_import_args /tmp/a.conf "-rf"
  assert_fail parse_import_args /tmp/sin-extension
  assert_fail parse_import_args NOMBRE
}

t_only_imported_servers_can_be_activated() {
  WG_SERVERS="$TMP/servers"; mkdir -p "$WG_SERVERS"
  make_conf "$WG_SERVERS/OK.conf"; chmod 600 "$WG_SERVERS/OK.conf"
  assert_ok vpn_load_server OK
  # Legible por otros: no lo creó wifi-publica-import.
  make_conf "$WG_SERVERS/LEGIBLE.conf"; chmod 644 "$WG_SERVERS/LEGIBLE.conf"
  assert_fail vpn_load_server LEGIBLE
  # Enlace a un fichero externo.
  make_conf "$TMP/externo.conf"; chmod 600 "$TMP/externo.conf"
  ln -s "$TMP/externo.conf" "$WG_SERVERS/ENLACE.conf"
  assert_fail vpn_load_server ENLACE
  # Propietario distinto del esperado (en uso real: root).
  assert_fail server_file_secure "$WG_SERVERS/OK.conf" 12345
  # Inexistente / rutas.
  assert_fail vpn_load_server NOEXISTE
  assert_fail vpn_load_server ../externo
  # La lista solo muestra los importados válidos.
  assert_eq "$(vpn_servers | tr '\n' ' ')" "OK "
}

t_sudoers_two_rules_without_argument_globs() {
  local out rules
  out=$(render_sudoers alice /usr/local/lib/wifi-publica)
  rules=$(grep -vE '^\s*(#|$)' <<<"$out")
  assert_eq "$(grep -c 'ALL=(root)' <<<"$rules")" 2
  assert_contains "$rules" "alice ALL=(root) NOPASSWD: /usr/local/lib/wifi-publica/bin/wifi-publica"$'\n'
  assert_contains "$rules" "alice ALL=(root) PASSWD: /usr/local/lib/wifi-publica/bin/wifi-publica-import"
  assert_contains "$rules" "Defaults!/usr/local/lib/wifi-publica/bin/wifi-publica-import timestamp_timeout=0"
  # La regla NOPASSWD no menciona el ejecutable de importación.
  ! grep 'NOPASSWD' <<<"$rules" | grep -q 'import' || fail "NOPASSWD alcanza a import"
  # Sin argumentos ni comodines en las reglas.
  ! grep -E 'ALL=\(root\)' <<<"$rules" | grep -qE '\*|wifi-publica(-import)? +[^ ]' || fail "regla con argumentos"
  assert_fail render_sudoers 'evil user' /usr/local/lib/wifi-publica
  assert_fail render_sudoers alice '/tmp/x y'
}

t_sudoers_passes_visudo() {
  have visudo || { echo "visudo no disponible: omitido"; return 0; }
  render_sudoers alice /usr/local/lib/wifi-publica >"$TMP/sudoers"
  visudo -cf "$TMP/sudoers" >/dev/null || fail "visudo rechaza el sudoers generado"
  sed 's/TU_USUARIO/alice/' "$ROOT/sudoers/wifi-publica" >"$TMP/sudoers.ej"
  visudo -cf "$TMP/sudoers.ej" >/dev/null || fail "visudo rechaza sudoers/wifi-publica"
}
