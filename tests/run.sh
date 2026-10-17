#!/usr/bin/env bash
# Runner de tests sin dependencias (bash puro). Solo prueba funciones puras:
# NO aplica nada al sistema (ni nft, ni nmcli, ni wg-quick).
#   ./tests/run.sh            todos
#   ./tests/run.sh nft        solo tests/test_nft.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
PASS=0 FAIL=0 FAILED=()

if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' N=$'\e[0m'; else G="" R="" N=""; fi

for file in tests/test_*.sh; do
  [[ -n ${1:-} && $file != "tests/test_$1.sh" ]] && continue
  echo "── ${file#tests/}"
  mapfile -t names < <(grep -oE '^t_[A-Za-z0-9_]+' "$file")
  for t in "${names[@]}"; do
    out=$(
      set -e
      # shellcheck source=/dev/null
      source "$ROOT/tests/lib.sh"
      # shellcheck source=/dev/null
      source "$ROOT/$file"
      "$t"
    ) 2>&1
    rc=$?
    if (( rc == 0 )); then
      PASS=$((PASS + 1)); printf '  %s✔%s %s\n' "$G" "$N" "$t"
    else
      FAIL=$((FAIL + 1)); FAILED+=("$t"); printf '  %s✗%s %s\n%s\n' "$R" "$N" "$t" "$(sed 's/^/      /' <<<"$out")"
    fi
  done
done

echo
echo "Resultado: $PASS ok, $FAIL fallos"
(( FAIL == 0 )) || { printf 'Fallos: %s\n' "${FAILED[*]}"; exit 1; }
