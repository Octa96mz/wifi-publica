# shellcheck shell=bash
# Medida 13 (opcional, --browser): Brave con perfil temporal en /tmp,
# incógnito y WebRTC limitado a la interfaz pública (no filtra IPs locales).
# Se lanza como TU usuario (nunca como root) desde el lanzador.

m_browser_launch() {
  local bin dir
  for bin in brave brave-browser; do have "$bin" && break; bin=""; done
  [[ -n $bin ]] || { warn "Brave no está instalado (instálalo con: omarchy pkg add brave-bin)"; return 0; }
  if (( DRY_RUN )); then
    run "$bin" --user-data-dir=/tmp/wp-brave.XXXXXX --incognito --no-first-run \
      --force-webrtc-ip-handling-policy=default_public_interface_only
    return 0
  fi
  dir=$(mktemp -d /tmp/wp-brave.XXXXXX)
  # El perfil se borra al cerrar el navegador.
  setsid -f bash -c '"$1" --user-data-dir="$2" --incognito --no-first-run \
      --force-webrtc-ip-handling-policy=default_public_interface_only >/dev/null 2>&1
    rm -rf -- "$2"' _ "$bin" "$dir"
  ok "Brave temporal abierto (perfil $dir, se borra al cerrarlo)"
}

m_browser_apply()  { :; }
m_browser_revert() { :; }
m_browser_check()  { echo "na|opcional: wifi-publica on --browser"; }
