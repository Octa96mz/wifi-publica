# shellcheck shell=bash
# Mensajes de la CLI (ejecución real con --dry-run como usuario: no cambia
# nada y no necesita root).

t_vpn_use_unknown_server_prints_a_single_error() {
  command -v wg-quick >/dev/null && command -v wg >/dev/null || { echo "sin wireguard-tools: omitido"; return 0; }
  local out rc=0
  out=$("$ROOT/bin/wifi-publica" --dry-run vpn use NOEXISTE 2>&1) || rc=$?
  assert_eq "$rc" 1 "$out"
  assert_eq "$(grep -c '✗' <<<"$out")" 1 "debe haber un solo error: $out"
  assert_contains "$out" "no existe el servidor 'NOEXISTE' (mira: wifi-publica vpn list)"
}

t_rescue_command_spelling() {
  # El comando de rescate debe nombrar la tabla real (sin erratas).
  local f
  # (La copia de preparación de install.sh solo lleva bin/ y lib/.)
  for f in "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/bin/wifi-publica" "$ROOT/lib/nft.sh" "$ROOT/docs/GUIA-PRUEBA.md"; do
    [[ -f $f ]] || continue
    ! grep -nE 'delete table inet wifipublica[^ `";]|wifipublicas' "$f" || fail "errata en $f"
  done
  grep -q "delete table inet $NFT_TABLE; sudo wg-quick down $WG_IFACE\$" <(grep -hs 'Recuperación de emergencia' "$ROOT/install.sh" "$ROOT/bin/wifi-publica") \
    || fail "el rescate no nombra la tabla $NFT_TABLE"
  # Las dos partes, separadas por ";" y no por "&&": si la tabla ya no
  # existe, "&&" se saltaría el "wg-quick down" (y el túnel seguiría
  # capturando todo el tráfico).
  for f in "$ROOT/install.sh" "$ROOT/README.md" "$ROOT/bin/wifi-publica" "$ROOT/docs/GUIA-PRUEBA.md"; do
    [[ -f $f ]] || continue
    grep -qF "nft delete table inet $NFT_TABLE; sudo wg-quick down $WG_IFACE" "$f" \
      || fail "falta el rescate completo (nft delete + wg-quick down) en $f"
    ! grep -nE "nft delete table inet $NFT_TABLE *&&" "$f" || fail "el rescate usa '&&' en $f"
  done
}
