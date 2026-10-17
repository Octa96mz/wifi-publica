# shellcheck shell=bash
# "remove <nombre>": solo en el ejecutable con contraseña, solo ficheros
# regulares 600 del dueño esperado dentro de servers/, nunca el activo ni con
# VPN/kill switch activos. Se ejecuta sin root sobre un servers/ temporal (el
# "dueño esperado" es entonces tu usuario, igual que EUID=0 → root en real).
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/cli.sh"
source "$ROOT/lib/import.sh"
source "$ROOT/lib/remove.sh"

setup_servers() {
  WG_SERVERS="$TMP/servers"; WG_LINK="$TMP/home.conf"; WP_STATE="$TMP/state.json"
  mkdir -p "$WG_SERVERS"; chmod 700 "$WG_SERVERS"
  local n
  for n in "$@"; do make_conf "$WG_SERVERS/$n.conf"; chmod 600 "$WG_SERVERS/$n.conf"; done
  DRY_RUN=0
  # Sin VPN real en los tests: "home" no existe.
  vpn_is_up() { return 1; }
}

# run_remove <nombre>: deja OUT (stdout+stderr) y RC.
run_remove() { RC=0; OUT=$(cmd_vpn_remove "$1" 2>&1) || RC=$?; }

t_remove_deletes_only_the_named_server() {
  setup_servers A-1 B-2 C-3
  ln -s servers/A-1.conf "$WG_LINK"
  run_remove B-2
  assert_eq "$RC" 0
  assert_contains "$OUT" "servidor 'B-2' eliminado"
  assert_contains "$OUT" "Servidores guardados: 2"
  [[ ! -e $WG_SERVERS/B-2.conf ]] || fail "no se borró"
  assert_eq "$(vpn_servers | tr '\n' ' ')" "A-1 C-3 "
  assert_eq "$(readlink "$WG_LINK")" servers/A-1.conf
  assert_not_contains "$OUT" "$FAKE_PRIV"
}

t_remove_invalid_names_rejected() {
  setup_servers A-1
  local n
  for n in "../servers/A-1" "/etc/passwd" "A-1.conf/.." "*" "A-?" "[A]-1" ".hidden" "a b" "" "-rf"; do
    assert_fail parse_remove_args remove "$n"
    run_remove "$n"
    [[ $RC != 0 ]] || fail "aceptado: '$n'"
  done
  [[ -f $WG_SERVERS/A-1.conf ]] || fail "se borró A-1"
}

t_remove_refuses_active_server() {
  setup_servers A-1 B-2
  ln -s servers/A-1.conf "$WG_LINK"
  run_remove A-1
  [[ $RC != 0 ]] || fail "borró el servidor activo"
  assert_contains "$OUT" "es el servidor ACTIVO"
  assert_contains "$OUT" "vpn use"
  [[ -f $WG_SERVERS/A-1.conf ]] || fail "falta A-1"
  # También si home.conf es un enlace con ruta absoluta (comparación por inodo).
  rm -f "$WG_LINK"; ln -s "$WG_SERVERS/B-2.conf" "$WG_LINK"
  run_remove B-2
  [[ $RC != 0 ]] || fail "borró el activo (enlace absoluto)"
}

t_remove_refuses_symlink_and_keeps_target() {
  setup_servers A-1
  make_conf "$TMP/fuera.conf"; chmod 600 "$TMP/fuera.conf"
  ln -s "$TMP/fuera.conf" "$WG_SERVERS/ENLACE.conf"
  run_remove ENLACE
  [[ $RC != 0 ]] || fail "aceptó un enlace"
  assert_contains "$OUT" "no es un fichero regular"
  [[ -L $WG_SERVERS/ENLACE.conf && -f $TMP/fuera.conf ]] || fail "tocó el enlace o su destino"
  assert_contains "$(head -n1 "$TMP/fuera.conf")" "[Interface]"
}

t_remove_refuses_missing_wrong_perms_and_dirs() {
  setup_servers A-1
  run_remove NOEXISTE
  [[ $RC != 0 ]] || fail "aceptó un inexistente"
  assert_contains "$OUT" "no existe el servidor 'NOEXISTE'"
  chmod 644 "$WG_SERVERS/A-1.conf"
  run_remove A-1
  [[ $RC != 0 ]] || fail "aceptó permisos 644"
  assert_contains "$OUT" "permisos 644"
  mkdir "$WG_SERVERS/DIR.conf"
  run_remove DIR
  [[ $RC != 0 && -d $WG_SERVERS/DIR.conf ]] || fail "aceptó un directorio"
}

t_remove_refuses_while_vpn_or_killswitch_active() {
  setup_servers A-1 B-2
  vpn_is_up() { return 0; }
  run_remove B-2
  [[ $RC != 0 ]] || fail "borró con la VPN activa"
  assert_contains "$OUT" "la VPN está activa"
  vpn_is_up() { return 1; }
  kv_set "$WP_STATE" vpn.killswitch 1
  run_remove B-2
  [[ $RC != 0 ]] || fail "borró con el kill switch activo"
  assert_contains "$OUT" "kill switch"
  [[ -f $WG_SERVERS/B-2.conf ]] || fail "falta B-2"
}

t_remove_parser_is_strict() {
  assert_ok parse_remove_args remove NL-FREE-16
  assert_eq "$REMOVE_NAME" NL-FREE-16
  assert_fail parse_remove_args remove
  assert_fail parse_remove_args remove A B
  assert_fail parse_remove_args remove --yes
  assert_fail parse_remove_args --dry-run remove A
  assert_fail parse_remove_args REMOVE A
  assert_fail parse_remove_args rm A
  # Por el ejecutable real: sin root se niega; opciones o extras, rechazados.
  local rc
  for args in "remove A-1" "remove A-1 B-2" "remove *" "--dry-run remove A-1" "remove ../x"; do
    rc=0
    # shellcheck disable=SC2086
    "$ROOT/bin/wifi-publica-import" $args >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 ]] || fail "'$args' aceptado sin root"
  done
}

t_main_binary_has_no_remove_or_import_code() {
  local main="$ROOT/bin/wifi-publica"
  ! grep -qE 'remove\.sh|import\.sh|^for _f in .*\b(remove|import)\b|cmd_vpn_remove|cmd_vpn_import|import_one|shred|parse_remove_args' "$main" \
    || fail "bin/wifi-publica contiene código de borrado o importación"
  ! grep -qE 'shred|cmd_vpn_remove' "$ROOT/lib/cli.sh" || fail "lib/cli.sh (cargado por bin/wifi-publica) contiene borrado"
  grep -qE '^for _f in .*\bremove\b' "$ROOT/bin/wifi-publica-import" || fail "wifi-publica-import no carga lib/remove.sh"
  # La tabla de rutas del script NOPASSWD rechaza "vpn remove" en todas sus formas.
  parse_args vpn remove A-1; assert_contains "$(route_root "${POS[@]}")" "reject:"
  parse_args --yes vpn remove A-1; assert_contains "$(route_root "${POS[@]}")" "reject:"
  parse_args vpn REMOVE A-1; assert_contains "$(route_root "${POS[@]}")" "reject:"
}
