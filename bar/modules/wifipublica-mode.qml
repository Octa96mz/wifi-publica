// Módulo "wifipublica-mode" (candado) para la barra de Omarchy shell.
// Copia en: ~/.config/omarchy/bar/modules/wifipublica-mode.qml
// y añade a bar.layout en ~/.config/omarchy/shell.json:
//   { "id": "wifipublica-mode", "type": "qml" }
//
// Colores: verde = activo con VPN · ámbar = activo sin VPN o portal ·
// rojo = kill switch SIN túnel (sin internet por diseño) · gris = inactivo.
// Clic izq.: activar/desactivar · Clic der.: portal cautivo.
import QtQuick
import Quickshell.Io

Item {
  id: root
  property var bar
  property string moduleName
  property var settings

  property var st: null
  readonly property string cli: settings && settings.command ? settings.command : "wifi-publica"
  readonly property string klass: st ? st.class : "inactive"

  readonly property color cGreen: "#9ece6a"
  readonly property color cAmber: "#e0af68"
  readonly property color cRed: "#f7768e"

  implicitWidth: label.implicitWidth + 14
  implicitHeight: bar ? bar.barSize : 26

  function tooltip() {
    if (!st) return "Wifi pública: estado desconocido"
    var names = {
      secure: "ACTIVO con VPN y kill switch",
      novpn: "ACTIVO sin VPN (dominios y metadatos visibles)",
      blocked: "Kill switch SIN túnel: sin internet",
      portal: "Portal cautivo: DNS/HTTP/HTTPS abiertos",
      inactive: "INACTIVO"
    }
    var t = "Wifi pública: " + (names[klass] || klass)
    t += "\nMedidas aplicadas: " + st.measures
    if (st.audit && st.audit.score !== null)
      t += "\nÚltimo audit: " + st.audit.score + "/100 (" + st.audit.at + ")"
    t += "\n\nClic: activar/desactivar · Clic der.: portal cautivo"
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

  FileView {
    path: "/run/wifi-publica/rev"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
  }

  Text {
    id: label
    anchors.centerIn: parent
    // Nerd Font: candado cerrado / abierto.
    text: root.klass === "inactive" ? "󰌿" : "󰌾"
    font.family: root.bar ? root.bar.fontFamily : "monospace"
    font.pixelSize: 13
    color: root.klass === "secure" ? root.cGreen
         : root.klass === "novpn" || root.klass === "portal" ? root.cAmber
         : root.klass === "blocked" ? root.cRed
         : (root.bar ? root.bar.foreground : "white")
    opacity: root.klass === "inactive" ? 0.5 : 1
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (!root.bar) return
      if (mouse.button === Qt.RightButton) root.bar.run(root.cli + " portal")
      else root.bar.run(root.cli + " toggle")
    }
  }
}
