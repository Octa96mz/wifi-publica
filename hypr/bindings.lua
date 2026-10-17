-- Atajos de wifi-publica para Omarchy (Hyprland con configuración en Lua).
-- Pega estas líneas al final de ~/.config/hypr/bindings.lua y valida con:
--   hyprctl reload && hyprctl configerrors
--
-- Comprueba antes que no estén en uso:
--   omarchy menu keybindings --print | grep -E 'SUPER (SHIFT )?ALT \+ [WV]$'
-- (el 13-10-2026 estaban libres; SUPER CTRL ALT + W es "Toggle weather").
-- Si alguno ya existe, añade antes hl.unbind("<tecla>").
--
-- Las notificaciones con el resultado las envía el propio script
-- (notify-send como tu usuario), también cuando falla.

o.bind("SUPER + ALT + W", "Wifi pública: activar/desactivar", "wifi-publica toggle")
o.bind("SUPER + SHIFT + ALT + W", "Wifi pública: portal cautivo", "wifi-publica portal")
o.bind("SUPER + ALT + V", "VPN: encender/apagar", "wifi-publica vpn toggle")
o.bind("SUPER + SHIFT + ALT + V", "VPN: elegir servidor", "wifi-publica vpn menu")
