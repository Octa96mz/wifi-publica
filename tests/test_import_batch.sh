# shellcheck shell=bash
# Importación por lotes: cada fichero pasa por el flujo seguro completo de
# forma independiente; los inválidos se omiten sin abortar el resto; nunca se
# sobrescribe; ninguna clave aparece en la salida; el límite es de 20; y una
# interrupción no deja servidores a medias ni temporales.
#
# Los tests "reales" escriben en un servers/ temporal SIN root: fijan
# IMPORT_REAL=1 a mano (en producción solo lo fija bin/wifi-publica-import,
# como root). No se toca /etc.
source "$ROOT/lib/vpn.sh"
source "$ROOT/lib/cli.sh"
source "$ROOT/lib/import.sh"
ME=$(id -u)

# mk <fichero> <último octeto del endpoint>: .conf válido con contenido propio.
mk() {
  make_conf "$1"
  sed -i "s/^Endpoint = .*/Endpoint = 192.0.2.$2:51820/" "$1"
}

# Prepara un servers/ temporal y el modo de escritura real (sin root).
setup_real() {
  WG_SERVERS="$TMP/servers"; WG_LINK="$TMP/home.conf"
  mkdir -p "$WG_SERVERS"; chmod 700 "$WG_SERVERS"
  DRY_RUN=0 IMPORT_REAL=1
}

# run_batch <ficheros...>: ejecuta el lote; deja OUT, ERR y RC.
run_batch() {
  IMPORT_FILES=("$@") IMPORT_NAME=""
  RC=0
  # Misma trampa que el punto de entrada (bin/wifi-publica-import).
  OUT=$(trap import_cleanup EXIT; cmd_vpn_import 2>"$TMP/stderr") || RC=$?
  ERR=$(cat "$TMP/stderr")
}

servers_list() { find "$WG_SERVERS" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }

t_batch_several_valid_including_path_with_spaces() {
  setup_real
  mkdir -p "$TMP/mis servidores vpn"
  mk "$TMP/mis servidores vpn/wg-NL-FREE-16.conf" 16
  mk "$TMP/mis servidores vpn/wg-US-FREE-117.conf" 117
  mk "$TMP/Laptop-NL-FREE-220.conf" 220
  run_batch "$TMP/mis servidores vpn/wg-NL-FREE-16.conf" "$TMP/mis servidores vpn/wg-US-FREE-117.conf" "$TMP/Laptop-NL-FREE-220.conf"
  assert_eq "$RC" 0
  assert_eq "$(servers_list)" "Laptop-NL-FREE-220.conf NL-FREE-16.conf US-FREE-117.conf "
  assert_contains "$OUT" "3 importados · 0 omitidos · 0 con error"
  assert_contains "$OUT" "Servidores guardados ahora: 3"
  assert_contains "$OUT" 'shred -u -- '
  assert_contains "$OUT" 'mis\ servidores\ vpn/wg-NL-FREE-16.conf'
  local f
  for f in "$WG_SERVERS"/*.conf; do
    assert_eq "$(stat -c %a "$f")" 600
    assert_ok wgconf_check "$f"
    assert_ok server_file_secure "$f" "$ME"
  done
  assert_eq "$(vpn_servers | tr '\n' ' ')" "Laptop-NL-FREE-220 NL-FREE-16 US-FREE-117 "
}

t_batch_mixed_invalid_skipped_rest_imported() {
  setup_real
  mk "$TMP/BUENO-1.conf" 1
  mk "$TMP/BUENO-2.conf" 2
  mk "$TMP/CONPOSTUP.conf" 3; sed -i "/^DNS/a PostUp = $FAKE_PRIV" "$TMP/CONPOSTUP.conf"
  ln -s /etc/hostname "$TMP/ENLACE.conf"
  mkfifo "$TMP/FIFO.conf"
  # El fichero de root (/etc/hostname) va en t_batch_root_owned_file_rejected:
  # no termina en .conf y el analizador lo rechazaría antes de llegar aquí.
  run_batch "$TMP/BUENO-1.conf" "$TMP/CONPOSTUP.conf" "$TMP/ENLACE.conf" "$TMP/FIFO.conf" "$TMP/BUENO-2.conf"
  assert_eq "$RC" 1 "con errores el código debe ser 1"
  assert_eq "$(servers_list)" "BUENO-1.conf BUENO-2.conf "
  assert_contains "$OUT" "2 importados · 0 omitidos · 3 con error"
  assert_contains "$OUT" "CONPOSTUP.conf: no válido: línea"
  assert_contains "$OUT" "clave no permitida en [Interface]: PostUp"
  assert_contains "$OUT" "ENLACE.conf: no es un fichero regular"
  assert_contains "$OUT" "FIFO.conf: no es un fichero regular"
  assert_not_contains "$OUT$ERR" "$FAKE_PRIV"
  assert_not_contains "$OUT$ERR" "TTTTTTTTTT"
  assert_eq "$(find "$WG_SERVERS" -name '.import-*' | wc -l)" 0
}

t_batch_root_owned_file_rejected() {
  setup_real
  [[ $(stat -c %u /etc/hostname) == 0 ]] || { echo "sin /etc/hostname de root: omitido"; return 0; }
  # El lote exige ".conf": se comprueba la apertura de /etc/hostname con el
  # mismo flujo de import_one (la extensión solo la exige el analizador).
  mk "$TMP/BUENO.conf" 9
  IMPORT_FILES=("$TMP/BUENO.conf" /etc/hostname) IMPORT_NAME=""
  RC=0; OUT=$(trap import_cleanup EXIT; cmd_vpn_import 2>"$TMP/stderr") || RC=$?
  assert_eq "$RC" 1
  assert_contains "$OUT" "hostname: lo abierto no es un fichero regular tuyo"
  assert_eq "$(servers_list)" "BUENO.conf "
}

t_batch_duplicate_names_first_wins() {
  setup_real
  mkdir -p "$TMP/a" "$TMP/b"
  mk "$TMP/a/wg-NL-FREE-1.conf" 11
  mk "$TMP/b/NL-FREE-1.conf" 12
  run_batch "$TMP/a/wg-NL-FREE-1.conf" "$TMP/b/NL-FREE-1.conf"
  assert_eq "$RC" 0
  assert_eq "$(servers_list)" "NL-FREE-1.conf "
  assert_contains "$OUT" "1 importados · 1 omitidos"
  assert_contains "$OUT" "nombre 'NL-FREE-1' repetido en el lote (ya lo aporta wg-NL-FREE-1.conf)"
  wgconf_check "$WG_SERVERS/NL-FREE-1.conf" >/dev/null
  assert_eq "$WGC_EP_HOST" 192.0.2.11 "debe quedarse el primero"
}

t_batch_existing_name_is_not_overwritten() {
  setup_real
  mk "$WG_SERVERS/NL-FREE-2.conf" 21; chmod 600 "$WG_SERVERS/NL-FREE-2.conf"
  local before; before=$(sha256sum "$WG_SERVERS/NL-FREE-2.conf")
  mk "$TMP/NL-FREE-2.conf" 22
  run_batch "$TMP/NL-FREE-2.conf"
  assert_eq "$RC" 0
  assert_contains "$OUT" "ya existe 'NL-FREE-2'"
  assert_contains "$OUT" "0 importados · 1 omitidos"
  assert_eq "$(sha256sum "$WG_SERVERS/NL-FREE-2.conf")" "$before"
}

t_batch_content_duplicate_warns_without_printing_keys() {
  setup_real
  # Mismo Endpoint y clave pública que un servidor ya guardado (como
  # Laptop-NL-FREE-220 frente al home.conf migrado).
  mk "$WG_SERVERS/migrado.conf" 220; chmod 600 "$WG_SERVERS/migrado.conf"
  mk "$TMP/Laptop-NL-FREE-220.conf" 220
  run_batch "$TMP/Laptop-NL-FREE-220.conf"
  assert_eq "$RC" 0
  assert_contains "$ERR" "mismo servidor (Endpoint y clave pública del peer) que 'migrado'"
  assert_eq "$(servers_list)" "Laptop-NL-FREE-220.conf migrado.conf "
  assert_not_contains "$OUT$ERR" "$FAKE_PUB"
  assert_not_contains "$OUT$ERR" "PPPPPPPPPP"
  assert_not_contains "$OUT$ERR" "$FAKE_PRIV"
}

t_batch_dry_run_writes_nothing_and_prints_no_keys() {
  WG_SERVERS="$TMP/servers"; mkdir -p "$WG_SERVERS"
  DRY_RUN=1 IMPORT_REAL=0
  mkdir -p "$TMP/con espacios"
  mk "$TMP/con espacios/wg-A-1.conf" 31
  mk "$TMP/wg-B-2.conf" 32
  run_batch "$TMP/con espacios/wg-A-1.conf" "$TMP/wg-B-2.conf"
  assert_eq "$RC" 0
  assert_contains "$OUT" "(dry-run) se importaría como 'A-1'"
  assert_eq "$(find "$WG_SERVERS" -mindepth 1 | wc -l)" 0 "dry-run escribió en servers/"
  assert_not_contains "$OUT$ERR" "$FAKE_PRIV"
  [[ -z $(find /tmp -maxdepth 1 -name 'wp-import.*' -user "$ME" 2>/dev/null) ]] || fail "quedan temporales en /tmp (función)"
  # Y con el ejecutable real, como usuario: rutas con espacios, sin claves,
  # sin temporales en /tmp.
  local o rc=0
  o=$("$ROOT/bin/wifi-publica-import" --dry-run "$TMP/con espacios/wg-A-1.conf" "$TMP/wg-B-2.conf" 2>"$TMP/e") || rc=$?
  assert_eq "$rc" 0
  assert_contains "$o" "2 importados · 0 omitidos · 0 con error"
  assert_not_contains "$o$(cat "$TMP/e")" "$FAKE_PRIV"
  assert_not_contains "$o$(cat "$TMP/e")" "TTTTTTTTTT"
  [[ -z $(find /tmp -maxdepth 1 -name 'wp-import.*' -user "$ME" 2>/dev/null) ]] || fail "quedan temporales en /tmp"
}

t_batch_limit_20_and_name_only_with_single_file() {
  local i files=()
  for i in $(seq 1 21); do files+=("$TMP/S$i.conf"); done
  assert_ok parse_import_args "${files[@]:0:20}"
  assert_eq "${#IMPORT_FILES[@]}" 20
  assert_fail parse_import_args "${files[@]}"
  local rc=0 o
  o=$("$ROOT/bin/wifi-publica-import" --dry-run "${files[@]}" 2>&1) || rc=$?
  assert_eq "$rc" 2
  assert_contains "$o" "máximo 20 ficheros"
  # [nombre] solo con un fichero.
  assert_ok parse_import_args "$TMP/a.conf" MI-NOMBRE
  assert_fail parse_import_args "$TMP/a.conf" "$TMP/b.conf" MI-NOMBRE
  # Longitud máxima de cada argumento.
  assert_fail parse_import_args "/tmp/$(printf 'a%.0s' $(seq 1 1100)).conf"
}

t_batch_relative_paths_use_original_cwd() {
  setup_real
  mkdir -p "$TMP/descargas"
  mk "$TMP/descargas/wg-REL-1.conf" 41
  ( cd "$TMP/descargas" && IMPORT_FILES=(wg-REL-1.conf) IMPORT_NAME="" && trap import_cleanup EXIT && cmd_vpn_import >/dev/null 2>&1 )
  assert_eq "$(servers_list)" "REL-1.conf "
}

t_batch_does_not_touch_home_link() {
  setup_real
  mk "$WG_SERVERS/ACTIVO.conf" 51; chmod 600 "$WG_SERVERS/ACTIVO.conf"
  ln -s servers/ACTIVO.conf "$WG_LINK"
  mk "$TMP/NUEVO.conf" 52
  run_batch "$TMP/NUEVO.conf"
  assert_eq "$(readlink "$WG_LINK")" servers/ACTIVO.conf
  # Sin home.conf, importar tampoco lo crea.
  rm -f "$WG_LINK"; mk "$TMP/OTRO.conf" 53
  run_batch "$TMP/OTRO.conf"
  [[ ! -e $WG_LINK && ! -L $WG_LINK ]] || fail "la importación creó home.conf"
}

t_batch_interrupted_leaves_no_partials() {
  local i files=() rc=0
  mkdir -p "$TMP/servers"; chmod 700 "$TMP/servers"
  for i in 1 2 3 4 5; do mk "$TMP/INT-$i.conf" "6$i"; files+=("$TMP/INT-$i.conf"); done
  # Arnés idéntico al punto de entrada (mismas trampas), con "sync"
  # interceptado para enviar SIGTERM justo con el 3.er temporal escrito y
  # antes de enlazarlo al nombre final.
  cat >"$TMP/harness.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT=$1; WG=$2; shift 2
for f in common state parse wgconf vpn cli import; do source "$ROOT/lib/$f.sh"; done
WG_SERVERS=$WG WG_LINK="$WG/../home.conf"
trap import_cleanup EXIT
trap 'exit 130' INT TERM HUP
DRY_RUN=0 IMPORT_REAL=1
N=0
sync() { N=$((N + 1)); if (( N == 3 )); then kill -TERM "$BASHPID"; fi; command sync "$@"; }
IMPORT_FILES=("$@") IMPORT_NAME=""
cmd_vpn_import
EOF
  bash "$TMP/harness.sh" "$ROOT" "$TMP/servers" "${files[@]}" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 130 "debe terminar por la señal"
  WG_SERVERS="$TMP/servers"
  assert_eq "$(servers_list)" "INT-1.conf INT-2.conf "
  assert_eq "$(find "$TMP/servers" -name '.import-*' | wc -l)" 0 "quedan temporales"
  local f
  for f in "$TMP/servers"/*.conf; do assert_ok wgconf_check "$f"; done
  # Un resto de kill -9 se purga al arrancar la siguiente importación.
  cp "$TMP/servers/INT-1.conf" "$TMP/servers/.import-out.ABC123"
  import_purge_stale
  assert_eq "$(find "$TMP/servers" -name '.import-*' | wc -l)" 0
}

t_static_parser_options_and_privsep() {
  # Opciones del analizador del importador: exactamente estas.
  local opts
  opts=$(sed -n '/^parse_import_args()/,/^}/p' "$ROOT/lib/cli.sh" | grep -oE '^\s+[^ (]+\)' | tr -d ' )' | sort | tr '\n' ' ')
  assert_eq "$opts" "* -* -- --dry-run|-n --yes|-y " "opciones del parser"
  # El script NOPASSWD sigue sin cargar ni usar el código de importación.
  ! grep -qE 'import\.sh|for _f in .*\bimport\b|cmd_vpn_import|import_one' "$ROOT/bin/wifi-publica" || fail "bin/wifi-publica carga código de importación"
  # Destino final: solo por enlace duro (no sobrescribe), nunca mv/cp/install a $dest.
  local body; body=$(sed -n '/^import_one()/,/^}/p' "$ROOT/lib/import.sh")
  assert_contains "$body" 'ln -T -- "$out" "$dest"'
  ! grep -qE '(mv|cp|install)[^#]*"\$dest"' <<<"$body" || fail "el destino se escribe sin protección contra sobrescritura"
}
