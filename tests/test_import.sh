# shellcheck shell=bash
# Importador: apertura única por descriptor, solo ficheros propios, sin
# enlaces/FIFOs/dispositivos, temporales que nunca parecen servidores, y la
# clave privada jamás en stdout/stderr.
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/cli.sh"
source "$ROOT/lib/import.sh"
ME=$(id -u)

t_fd_accepts_own_regular_file_and_reads_from_it() {
  make_conf "$TMP/own.conf"
  open_owned_regular "$TMP/own.conf" "$ME" || fail "rechazado: $IMPORT_ERR"
  [[ $IMPORT_FD =~ ^[0-9]+$ ]] || fail "sin descriptor"
  local first; first=$(head -n1 <&"$IMPORT_FD")
  exec {IMPORT_FD}<&-
  assert_eq "$first" "[Interface]"
}

t_fd_rejects_foreign_file_on_the_descriptor() {
  local f=/etc/passwd
  [[ $(stat -c %u "$f") == 0 ]] || { echo "sin fichero de root legible: omitido"; return 0; }
  # La comprobación previa (lstat) la pasa: es un fichero regular...
  _is_regular_mode "$(stat -c %f "$f")" || fail "/etc/passwd debería ser regular"
  # ...y la rechaza la comprobación sobre el descriptor abierto (dueño root).
  assert_fail open_owned_regular "$f" "$ME"
  open_owned_regular "$f" "$ME" || true
  assert_contains "$IMPORT_ERR" "lo abierto no es un fichero regular tuyo"
  # Directamente sobre un descriptor ya abierto: decide el fichero real.
  local fd
  exec {fd}</etc/passwd
  assert_fail fd_owned_regular "$fd" "$ME"
  exec {fd}<&-
  make_conf "$TMP/mio.conf"
  exec {fd}<"$TMP/mio.conf"
  assert_ok fd_owned_regular "$fd" "$ME"
  assert_fail fd_owned_regular "$fd" 0
  exec {fd}<&-
}

t_symlink_to_root_file_created_by_user_is_rejected() {
  ln -s /etc/passwd "$TMP/trampa.conf"
  assert_fail open_owned_regular "$TMP/trampa.conf" "$ME"
  open_owned_regular "$TMP/trampa.conf" "$ME" || true
  assert_contains "$IMPORT_ERR" "enlace simbólico"
  # Tampoco se acepta un enlace a un fichero propio (siempre se rechazan).
  make_conf "$TMP/real.conf"; ln -s "$TMP/real.conf" "$TMP/enlace.conf"
  assert_fail open_owned_regular "$TMP/enlace.conf" "$ME"
}

t_fifo_device_dir_and_unreadable_rejected_without_blocking() {
  mkfifo "$TMP/fifo.conf"
  # timeout: si se intentara abrir el FIFO, se quedaría bloqueado.
  timeout 3 bash -c 'source "$1/tests/lib.sh"; source "$1/lib/import.sh"
    ! open_owned_regular "$2" "$(id -u)"' _ "$ROOT" "$TMP/fifo.conf" || fail "FIFO aceptado o bloqueado"
  assert_fail open_owned_regular /dev/null "$ME"
  assert_fail open_owned_regular "$TMP" "$ME"
  assert_fail open_owned_regular "$TMP/no-existe.conf" "$ME"
  # Fichero regular propio pero ilegible: la apertura falla sin abortar.
  make_conf "$TMP/ilegible.conf"; chmod 000 "$TMP/ilegible.conf"
  if (( ME != 0 )); then
    assert_fail open_owned_regular "$TMP/ilegible.conf" "$ME"
    open_owned_regular "$TMP/ilegible.conf" "$ME" || true
    assert_eq "$IMPORT_ERR" "no se pudo abrir"
  fi
}

t_oversized_file_rejected_on_descriptor() {
  head -c 9000 /dev/zero | tr '\0' 'a' >"$TMP/grande.conf"
  assert_fail open_owned_regular "$TMP/grande.conf" "$ME"
}

t_temp_names_never_look_like_servers() {
  WG_SERVERS="$TMP/servers"; mkdir -p "$WG_SERVERS"
  make_conf "$WG_SERVERS/NL-FREE-1.conf"; chmod 600 "$WG_SERVERS/NL-FREE-1.conf"
  local t
  for t in src out; do
    f=$(mktemp "$WG_SERVERS/${IMPORT_TMP_PREFIX}$t.XXXXXX")
    make_conf "$f"; chmod 600 "$f"
    [[ $f != *.conf ]] || fail "temporal con nombre de servidor: $f"
  done
  assert_eq "$(vpn_servers | tr '\n' ' ')" "NL-FREE-1 "
  # Y la purga de restos solo borra temporales, nunca servidores.
  import_purge_stale
  assert_eq "$(find "$WG_SERVERS" -mindepth 1 | wc -l)" 1
  [[ -f $WG_SERVERS/NL-FREE-1.conf ]] || fail "la purga borró un servidor"
}

t_dry_run_import_never_prints_private_key() {
  local out rc
  make_conf "$TMP/wg-TEST-FREE-1.conf"
  # Caso válido.
  rc=0
  out=$("$ROOT/bin/wifi-publica-import" --dry-run "$TMP/wg-TEST-FREE-1.conf" 2>"$TMP/err") || rc=$?
  assert_eq "$rc" 0
  assert_contains "$out" "se importaría como 'TEST-FREE-1'"
  assert_not_contains "$out$(cat "$TMP/err")" "$FAKE_PRIV"
  assert_not_contains "$out$(cat "$TMP/err")" "TTTTTTTTTT"
  # Caso inválido (la ruta de error también debe callar la clave): clave
  # prohibida con la clave privada como valor y Address rota.
  make_conf "$TMP/malo.conf" "PostUp = $FAKE_PRIV"
  sed -i 's/^Address = .*/Address = rota/' "$TMP/malo.conf"
  rc=0
  out=$("$ROOT/bin/wifi-publica-import" --dry-run "$TMP/malo.conf" 2>"$TMP/err") || rc=$?
  [[ $rc != 0 ]] || fail "un .conf inválido no debería importarse"
  assert_contains "$out$(cat "$TMP/err")" "clave no permitida"
  assert_not_contains "$out$(cat "$TMP/err")" "$FAKE_PRIV"
  assert_not_contains "$out$(cat "$TMP/err")" "TTTTTTTTTT"
  # Ningún temporal del importador queda en /tmp.
  [[ -z $(find /tmp -maxdepth 1 -name 'wp-import.*' -user "$ME" 2>/dev/null) ]] || fail "quedan temporales en /tmp"
}

t_import_uses_descriptor_not_path_checks() {
  # Estática: el importador no vuelve a abrir la ruta de origen por nombre.
  local body; body=$(sed -n '/^import_one()/,/^}/p' "$ROOT/lib/import.sh")
  assert_contains "$body" 'open_owned_regular "$src"'
  assert_contains "$body" '<&"$IMPORT_FD"'
  ! grep -qE '(head|cat|cp|install|wgconf_check)[^|]*"\$(src|real)"' <<<"$body" || fail "se lee la ruta de origen por nombre"
  ! grep -q 'readlink' <<<"$body" || fail "resuelve enlaces de la ruta de origen"
  ! grep -qE 'mktemp[^)]*\.conf' "$ROOT/lib/import.sh" || fail "plantilla temporal terminada en .conf"
}
