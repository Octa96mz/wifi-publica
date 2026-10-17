// Módulo "wifipublica-vpn" para la barra de Omarchy shell (Quickshell).
// Copia en: ~/.config/omarchy/bar/modules/wifipublica-vpn.qml
// y añade a bar.layout en ~/.config/omarchy/shell.json:
//   { "id": "wifipublica-vpn", "type": "qml" }
//
// Solo usa la API documentada en /usr/share/omarchy/shell/plugins/bar/README.md
// (bar.run, bar.showTooltip/hideTooltip, bar.foreground, bar.fontFamily,
// bar.barSize) y Quickshell.Io (Process, StdioCollector, FileView).
// En lugar de las señales RTMIN de Waybar (aquí no existen), vigila
// /run/wifi-publica/rev, que el script reescribe tras cada acción.
//
// Clic izq.: encender/apagar · Clic der.: elegir servidor · Shift + rueda:
// servidor siguiente/anterior (la rueda sola no hace nada: un giro accidental
// no debe cambiar de servidor). El resultado lo notifica el propio script.
import QtQuick
import Quickshell.Io

Item {
  id: root
  property var bar
  property string moduleName
  property var settings

  property var st: null
  property bool busy: false
  readonly property string cli: settings && settings.command ? settings.command : "wifi-publica"
  readonly property var vpn: st && st.vpn ? st.vpn : null
  readonly property string vclass: vpn ? vpn.class : "unknown"

  readonly property color cGreen: "#9ece6a"
  readonly property color cAmber: "#e0af68"
  readonly property color cRed: "#f7768e"

  implicitWidth: label.implicitWidth + 14
  implicitHeight: bar ? bar.barSize : 26

  function human(n) {
    if (n === null || n === undefined) return "?"
    var u = ["B", "KiB", "MiB", "GiB", "TiB"], i = 0
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++ }
    return (i === 0 ? n : n.toFixed(1)) + " " + u[i]
  }

  function tooltip() {
    if (!vpn) return "VPN: estado desconocido"
    var t = "VPN: " + (vpn.up ? "conectada" : "desconectada")
    t += "\nServidor: " + (vpn.server || "(ninguno)")
    if (vpn.up) {
      t += "\nIP pública: " + (vpn.public_ip || "?")
      t += "\nÚltimo handshake: " + (vpn.handshake_age === null ? "?" : "hace " + vpn.handshake_age + " s")
      t += "\n↓ " + human(vpn.rx) + "   ↑ " + human(vpn.tx)
    }
    if (vpn.error) t += "\nÚltimo error: " + vpn.error
    if (st && st.killswitch) t += "\nKill switch ACTIVO"
    t += "\n\nClic: encender/apagar · Clic der.: servidores · Shift+rueda: cambiar"
    return t
  }

  function refresh() { if (!proc.running) proc.running = true }

  Process {
    id: proc
    command: ["bash", "-lc", root.cli + " status --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.st = JSON.parse(text) } catch (e) { root.st = null }
      }
    }
  }

  Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { id: cooldown; interval: 1200; onTriggered: root.busy = false }

  FileView {
    path: "/run/wifi-publica/rev"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
  }

  Text {
    id: label
    anchors.centerIn: parent
    // Nerd Font: escudo relleno = conectada, escudo vacío = desconectada.
    text: root.vclass === "connected" || root.vclass === "stale" ? "󰒘" : "󰒙"
    font.family: root.bar ? root.bar.fontFamily : "monospace"
    font.pixelSize: 13
    color: root.vclass === "connected" ? root.cGreen
         : root.vclass === "stale" ? root.cAmber
         : root.vclass === "error" ? root.cRed
         : (root.bar ? root.bar.foreground : "white")
    opacity: root.vclass === "disconnected" || root.vclass === "unknown" ? 0.5 : 1
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (!root.bar) return
      if (mouse.button === Qt.RightButton) root.bar.run(root.cli + " vpn menu")
      else root.bar.run(root.cli + " vpn toggle")
    }
    onWheel: function(wheel) {
      wheel.accepted = true
      if (!(wheel.modifiers & Qt.ShiftModifier)) return
      // Con Shift, algunos entornos convierten la rueda en horizontal (x).
      var d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x
      if (d === 0 || !root.bar || root.busy) return
      root.busy = true
      cooldown.restart()
      root.bar.run(root.cli + (d > 0 ? " vpn next" : " vpn prev"))
    }
  }
}
