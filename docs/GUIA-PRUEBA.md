# Guía de prueba segura desde casa

Hazla en casa, con tiempo y con acceso físico al portátil. Antes de empezar,
ten a mano el **plan de recuperación** (al final). Ningún paso cambia nada
de forma permanente: todo es en tiempo de ejecución y un reinicio lo borra.

## 0. Sin instalar nada

```bash
cd ~/wifi-publica
./tests/run.sh                               # tests de funciones puras
unshare -rn ./tests/netns-killswitch.sh      # kill switch real en un namespace aislado
./bin/wifi-publica --dry-run on              # plan (sin root: parte se omite)
```

Revisa la salida del dry-run: los `systemctl stop`, los `docker pause`, la
orden `nmcli … --temporary` y la tabla nftables que se cargaría.

## 1. Instalar

```bash
less install.sh          # léelo
./install.sh --dry-run   # sin sudo: tests sobre una copia, sudoers validado y lista de lo que crearía
sudo ./install.sh
```

- Si tienes `/etc/wireguard/home.conf`, te pedirá un nombre (por ejemplo `NL-FREE-220`) y lo migrará; el original queda en `/etc/wireguard/home.conf.pre-wifi-publica`.
- Comprueba: `ls -l /usr/local/lib/wifi-publica /etc/sudoers.d/wifi-publica`. Todo debe ser de root.

Plan completo con root (sigue sin cambiar nada):

```bash
sudo wifi-publica --dry-run on
```

## 2. Servidores VPN

Importa todos de una vez (hasta 20 por llamada). Primero en dry-run, que no
pide contraseña ni escribe nada (si la ruta tiene espacios, ponla entre
comillas):

```bash
wifi-publica --dry-run vpn import ~/Downloads/vpn/*.conf ~/Downloads/otro.conf
wifi-publica vpn import ~/Downloads/vpn/*.conf ~/Downloads/otro.conf
wifi-publica vpn list
```

- Pide **tu contraseña una sola vez** por llamada (siempre, sin caché de sudo). El resto de comandos no la piden: compruébalo con `wifi-publica vpn list`.
- El nombre de cada servidor sale del fichero (`wg-NL-FREE-16.conf` → `NL-FREE-16`). Si el nombre no es válido o ya existe, ese fichero **se omite** (nunca se sobrescribe) y el lote sigue. Lo mismo con ficheros inválidos (por ejemplo, con `PostUp`), enlaces, FIFOs o ficheros que no son tuyos.
- Si dos ficheros son el mismo servidor (mismo Endpoint y clave pública), por ejemplo `otro.conf` y el `home.conf` migrado, se avisa pero se importa.
- Importar no cambia el servidor activo: elige uno con `wifi-publica vpn use <nombre>`.
- Un nombre propio solo con un fichero: `wifi-publica vpn import ~/Downloads/x.conf MI-NOMBRE`.
- Para borrar un servidor guardado (pide contraseña): `sudo /usr/local/lib/wifi-publica/bin/wifi-publica-import remove <nombre>`. Se niega si es el servidor activo (cambia antes con `vpn use`) o si la VPN o el modo están activos. Ojo: en btrfs y con los snapshots de snapper, `shred` no garantiza que la clave sea irrecuperable del disco.

Al final verás el resumen (importados / omitidos / con error) y la orden
`shred -u -- …` exacta para borrar los originales importados, que contienen
tu clave privada y los puede leer cualquier usuario del equipo. Ejecútala tú
cuando hayas comprobado que todo funciona.

## 3. Capa VPN sola (modo inactivo)

```bash
wifi-publica vpn on          # handshake ≤15 s + la IP pública debe cambiar
wifi-publica vpn status
curl -s https://api.ipify.org; echo
wifi-publica vpn use NL-FREE-16
wifi-publica vpn next
wifi-publica vpn menu        # selector gráfico
wifi-publica vpn off
```

Comprueba que tras `vpn off` vuelves a tener tu IP normal.

## 4. Modo wifi pública

```bash
wifi-publica on              # al final ejecuta el audit y te notifica
wifi-publica status
wifi-publica audit
```

Comprobaciones:

```bash
curl -s https://api.ipify.org; echo         # IP de Proton
resolvectl status home | grep -E 'DNS Servers|DNS Domain'   # 10.2.0.1 y ~.
ip link show wlan0 | grep permaddr           # MAC aleatoria
sudo nft list table inet wifipublica         # la tabla
docker ps                                     # webapp y proxy en "Paused"
```

Prueba el kill switch con el modo activo:

```bash
wifi-publica vpn off         # pedirá confirmación; tras ella NO hay internet
curl -m 5 https://example.com || echo "bloqueado (correcto)"
wifi-publica vpn on          # vuelve internet
```

Prueba el cambio de servidor con el kill switch activo:

```bash
wifi-publica vpn use US-FREE-117
sudo nft list chain inet wifipublica output | grep wp-endpoint   # IP nueva
```

## 5. Portal cautivo (simulado)

```bash
wifi-publica portal --seconds 60
systemctl list-timers wifi-publica-portal.timer
# espera 60 s o ejecuta:
wifi-publica on
```

## 6. Desactivar y comprobar que todo vuelve

```bash
wifi-publica off
wifi-publica audit           # ahora casi todo en rojo: es lo esperado
docker ps                    # contenedores en marcha de nuevo
systemctl is-active cups avahi-daemon
nmcli -g 802-11-wireless.cloned-mac-address connection show "<tu wifi>"   # vacío otra vez
sudo nft list tables         # sin "wifipublica"
```

## Plan de recuperación (si algo sale mal)

En orden, de menos a más drástico:

1. `wifi-publica off`
2. Si no responde o falla:
   ```bash
   sudo nft delete table inet wifipublica; sudo wg-quick down home   # quita firewall y kill switch, y baja la VPN
   sudo systemctl stop wifi-publica-portal.timer
   ```
   Hacen falta las dos partes: wg-quick envía todo el tráfico sin su marca a la tabla de rutas 51820, es decir, al túnel; si solo quitas el firewall y el túnel está caído, sigues sin red.
3. Si la wifi sigue rara (MAC, DNS, IPv6), los cambios eran `--temporary` (solo en memoria; NetworkManager los guarda en `/run`, así que un reinicio los borra). Para dejarlos a mano con los valores por defecto de NetworkManager:
   ```bash
   nmcli connection modify --temporary "<tu wifi>" \
     802-11-wireless.cloned-mac-address "" ipv4.ignore-auto-dns no ipv4.dns "" \
     ipv6.ignore-auto-dns no connection.dns-over-tls -1 connection.mdns -1 \
     connection.llmnr -1 ipv4.dhcp-send-hostname -1 ipv6.dhcp-send-hostname -1 \
     ipv6.method auto
   nmcli connection up "<tu wifi>"
   ```
4. Docker: `docker unpause webapp proxy`
5. Servicios: `sudo systemctl start cups.socket avahi-daemon.socket sshd` (los que usaras).
6. **Reiniciar** lo deshace todo: nada era persistente y `/run/wifi-publica` se borra.

El registro está en `/var/log/wifi-publica.log` (`sudo tail -50 /var/log/wifi-publica.log`).
