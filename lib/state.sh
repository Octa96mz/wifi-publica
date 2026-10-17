# shellcheck shell=bash
# Estado en ficheros JSON planos {"clave": "valor"} sin depender de jq.
# Las claves usan [a-z0-9_.-]; los valores son cadenas de una sola línea.

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

json_unescape() {
  local s=$1
  s=${s//\\\\/$'\x01'}
  s=${s//\\\"/\"}
  s=${s//$'\x01'/\\}
  printf '%s' "$s"
}

valid_key() { [[ $1 =~ ^[a-z0-9_.-]{1,64}$ ]]; }

# kv_read <fichero>: imprime "clave<TAB>valor" por cada entrada.
kv_read() {
  local f=$1 line re='^[[:space:]]*"([a-z0-9_.-]+)":[[:space:]]*"(.*)",?[[:space:]]*$'
  [[ -r $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $re ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$(json_unescape "${BASH_REMATCH[2]}")"
    fi
  done <"$f"
}

# En --dry-run no se escribe nada: los cambios se guardan en memoria para que
# el plan mostrado refleje el estado que habría (p. ej. reglas del portal).
declare -gA WP_DRY_KV=()

kv_get() {
  local f=$1 key=$2 k v
  if (( DRY_RUN )) && [[ -v WP_DRY_KV["$f|$key"] ]]; then
    v=${WP_DRY_KV["$f|$key"]}
    [[ $v == $'\x02DEL' ]] && return 1
    printf '%s' "$v"
    return 0
  fi
  while IFS=$'\t' read -r k v; do
    if [[ $k == "$key" ]]; then printf '%s' "$v"; return 0; fi
  done < <(kv_read "$f")
  return 1
}

kv_has() { kv_get "$1" "$2" >/dev/null; }

# kv_write <fichero> <clave> <valor> [<clave> <valor>...] (valor "\0DEL" borra)
kv_write() {
  local f=$1; shift
  if (( DRY_RUN )); then
    while (( $# >= 2 )); do
      valid_key "$1" || die "clave de estado no válida: $1"
      WP_DRY_KV["$f|$1"]=${2//[$'\n\t\r']/ }
      shift 2
    done
    return 0
  fi
  local -A data=()
  local -a order=()
  local k v tmp i n
  while IFS=$'\t' read -r k v; do
    [[ -v data[$k] ]] || order+=("$k")
    data[$k]=$v
  done < <(kv_read "$f")
  while (( $# >= 2 )); do
    k=$1 v=$2; shift 2
    valid_key "$k" || die "clave de estado no válida: $k"
    v=${v//[$'\n\t\r']/ }
    if [[ $v == $'\x02DEL' ]]; then
      unset 'data[$k]'
      continue
    fi
    [[ -v data[$k] ]] || order+=("$k")
    data[$k]=$v
  done
  tmp=$(mktemp "${f%/*}/.state.XXXXXX")
  {
    printf '{\n'
    n=0
    for k in "${order[@]}"; do [[ -v data[$k] ]] && n=$((n + 1)); done
    i=0
    for k in "${order[@]}"; do
      [[ -v data[$k] ]] || continue
      i=$((i + 1))
      printf '  "%s": "%s"%s\n' "$k" "$(json_escape "${data[$k]}")" "$([[ $i -lt $n ]] && printf ',')"
    done
    printf '}\n'
  } >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$f"
}

kv_set() { kv_write "$@"; }
kv_del() { local f=$1; shift; local a=() k; for k in "$@"; do a+=("$k" $'\x02DEL'); done; kv_write "$f" "${a[@]}"; }

# Atajos para el estado del modo.
st_get() { kv_get "$WP_STATE" "$1"; }
st_has() { kv_has "$WP_STATE" "$1"; }
st_set() { kv_set "$WP_STATE" "$@"; }
st_del() { kv_del "$WP_STATE" "$@"; }
vs_get() { kv_get "$WP_VPNSTATE" "$1"; }
vs_set() { kv_set "$WP_VPNSTATE" "$@"; }

mode_get() { st_get mode 2>/dev/null || printf 'inactive'; }

applied_list() { st_get applied 2>/dev/null || true; }
applied_has() { [[ " $(applied_list) " == *" $1 "* ]]; }
applied_add() {
  applied_has "$1" && return 0
  local l; l=$(applied_list)
  st_set applied "${l:+$l }$1"
}
applied_del() {
  local out=() m
  for m in $(applied_list); do [[ $m == "$1" ]] || out+=("$m"); done
  st_set applied "${out[*]}"
}
applied_count() { local a; read -r -a a <<<"$(applied_list)"; printf '%s' "${#a[@]}"; }
