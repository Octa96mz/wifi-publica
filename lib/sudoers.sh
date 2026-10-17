# shellcheck shell=bash
# Genera /etc/sudoers.d/wifi-publica (lo usan install.sh y los tests).
#
# Cómo decide sudo qué regla aplica:
#  - Compara usuario, host, usuario destino y COMANDO. El comando se compara
#    por ruta y, si el usuario llega por otra ruta (relativa, enlace...), por
#    el dispositivo/inodo del fichero real. Cada regla solo puede ejecutar SU
#    fichero: por ninguna ruta se llega a wifi-publica-import con la regla
#    de wifi-publica, porque son ficheros (inodos) distintos.
#  - Si varias reglas coinciden, gana la ÚLTIMA que aparezca.
#  - Aquí ninguna regla lleva argumentos: cada una permite cualquier
#    argumento para UN fichero concreto. No se usan comodines en argumentos
#    porque son evadibles: una regla con contraseña para "wifi-publica vpn
#    import *" no coincide con "--yes vpn import f" ni con "-- vpn import f",
#    que caerían en la regla sin contraseña. Y al revés, "*" en argumentos
#    también abarca espacios: "NOPASSWD: wifi-publica vpn *" permitiría
#    "vpn import f".
#
# render_sudoers <usuario> <directorio_instalación>
render_sudoers() {
  local u=$1 dir=$2
  [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ $dir =~ ^/[A-Za-z0-9/._-]+$ ]] || return 1
  cat <<EOF
# /etc/sudoers.d/wifi-publica — generado por install.sh. Valídalo con visudo -c.
#
# 1) Uso normal SIN contraseña: solo el script principal. No puede importar
#    servidores: ese código no existe en él (está en wifi-publica-import).
$u ALL=(root) NOPASSWD: $dir/bin/wifi-publica

# 2) Importar servidores CON contraseña, pedida SIEMPRE (sin caché de sudo).
Defaults!$dir/bin/wifi-publica-import timestamp_timeout=0
$u ALL=(root) PASSWD: $dir/bin/wifi-publica-import
EOF
}
