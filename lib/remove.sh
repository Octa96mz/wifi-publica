# shellcheck shell=bash
# Borrado de servidores guardados. SOLO lo carga bin/wifi-publica-import
# (regla sudoers CON contraseña); bin/wifi-publica no contiene este código.
#
# Uso: sudo /usr/local/lib/wifi-publica/bin/wifi-publica-import remove <nombre>
#
# Aviso: en btrfs (copy-on-write, con compresión) y en otros sistemas con
# journaling o snapshots, "shred" NO garantiza sobrescribir los bloques
# originales, y los snapshots (snapper) conservan copias del fichero. El
# borrado elimina el servidor de forma fiable; la clave privada puede seguir
# recuperable en disco o en snapshots antiguos. Si una clave se ve
# comprometida, revócala en la web de Proton (genera una nueva).

# parse_remove_args <args...>: exactamente "remove <nombre>". Sin opciones,
# sin más argumentos y sin comodines (el nombre debe cumplir la misma regex
# que "vpn use", que no admite '*', '?', '[', '/' ni '..').
REMOVE_NAME=""
parse_remove_args() {
  REMOVE_NAME=""
  if (( $# != 2 )) || [[ $1 != remove ]]; then
    echo "uso: wifi-publica-import remove <nombre>   (un único nombre, sin opciones)" >&2
    return 2
  fi
  if ! valid_server_name "$2"; then
    echo "nombre no válido: usa letras, números, '.', '_' o '-' (máx. 48), sin comodines ni rutas" >&2
    return 2
  fi
  # shellcheck disable=SC2034  # resultado para bin/wifi-publica-import
  REMOVE_NAME=$2
}

# cmd_vpn_remove <nombre>: devuelve 0 si lo borra; si se niega, muere con
# un mensaje (sin contenido del fichero).
cmd_vpn_remove() {
  local name=$1 f mode perm owner active=""
  # shellcheck disable=SC2034  # WP_CMD lo lee log() en lib/common.sh
  WP_CMD="vpn remove"
  valid_server_name "$name" || die "nombre no válido" 2
  f=$(vpn_server_file "$name")

  # Fichero regular (lstat: sin seguir enlaces), del dueño esperado (root en
  # uso real) y con permisos exactamente 600.
  mode=$(stat -c '%f' -- "$f" 2>/dev/null) || die "no existe el servidor '$name' (mira: wifi-publica vpn list)"
  _is_regular_mode "$mode" || die "'$name' no es un fichero regular (¿enlace simbólico?): no se borra"
  owner=$(stat -c '%u' -- "$f")
  perm=$(stat -c '%a' -- "$f")
  [[ $owner == "$EUID" ]] || die "'$name' no pertenece a root: no se borra"
  [[ $perm == 600 ]] || die "'$name' tiene permisos $perm (se esperaba 600): no se borra"

  # No con la VPN o el kill switch activos, ni el servidor activo.
  if vpn_is_up; then
    die "la VPN está activa: apágala (wifi-publica vpn off) antes de borrar servidores"
  fi
  if [[ $(st_get vpn.killswitch 2>/dev/null || echo 0) == 1 ]] || { have nft && nft list table inet "$NFT_TABLE" >/dev/null 2>&1; }; then
    die "el modo wifi pública / kill switch está activo: desactívalo (wifi-publica off) antes de borrar servidores"
  fi
  active=$(vpn_active_server 2>/dev/null || true)
  if [[ $active == "$name" ]] || { [[ -e $WG_LINK ]] && [[ $f -ef $WG_LINK ]]; }; then
    die "'$name' es el servidor ACTIVO: cambia primero a otro con 'wifi-publica vpn use <otro>'"
  fi

  if have shred; then
    shred -u -- "$f" || die "no se pudo borrar '$name'"
  else
    rm -f -- "$f" || die "no se pudo borrar '$name'"
  fi
  log "servidor eliminado: $name"
  ok "servidor '$name' eliminado"
  say "Servidores guardados: $(vpn_servers | grep -c . || true)"
  say "Nota: en btrfs y con snapshots, shred no garantiza que la clave sea irrecuperable del disco."
  bump_rev
}
