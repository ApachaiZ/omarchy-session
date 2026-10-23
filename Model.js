// Parse `hyprctl monitors -j` output into a display list ready for the QML.
// Each display carries its available modes (resolution@refresh, deduped) and
// the current mode, transform, and enabled/focused flags.

function parseMonitors(jsonText) {
  var monitors = []
  try {
    monitors = JSON.parse(String(jsonText || ""))
  } catch (e) {
    monitors = []
  }
  if (!Array.isArray(monitors)) monitors = []

  return monitors.map(function (m) {
    var modes = []
    var seen = {}
    if (Array.isArray(m.availableModes)) {
      for (var i = 0; i < m.availableModes.length; i++) {
        var raw = String(m.availableModes[i]).trim()
        var value = raw.replace(/Hz\s*$/i, "")
        if (!value || seen[value]) continue
        seen[value] = true

        var at = value.lastIndexOf("@")
        var res = at >= 0 ? value.slice(0, at) : value
        var refresh = at >= 0 ? value.slice(at + 1) : ""
        var dims = res.split("x")
        modes.push({
          value: value,
          label: res.replace("x", "\u00d7") + " @ " + refresh + " Hz",
          width: parseInt(dims[0], 10) || 0,
          height: parseInt(dims[1], 10) || 0,
          refresh: parseFloat(refresh) || 0
        })
      }
    }

    var refresh = Math.round((Number(m.refreshRate) || 0) * 100) / 100
    var currentMode = (Number(m.width) || 0) + "x" + (Number(m.height) || 0) + "@" + refresh

    return {
      name: m.name || "",
      enabled: m.disabled !== true,
      focused: m.focused === true,
      transform: Number(m.transform) || 0,
      scale: m.scale,
      width: Number(m.width) || 0,
      height: Number(m.height) || 0,
      refreshRate: Number(m.refreshRate) || 0,
      currentMode: currentMode,
      modes: modes
    }
  })
}

// Pick the available-mode value that best matches the display's live mode,
// falling back to the reconstructed current-mode string when no mode matches.
function currentModeValue(display) {
  if (!display || !Array.isArray(display.modes) || display.modes.length === 0) {
    return display ? display.currentMode : ""
  }
  var best = display.currentMode
  var bestDist = Infinity
  var targetRefresh = Math.round((Number(display.refreshRate) || 0) * 100) / 100
  for (var i = 0; i < display.modes.length; i++) {
    var m = display.modes[i]
    var dw = Math.abs(m.width - display.width)
    var dh = Math.abs(m.height - display.height)
    var dr = Math.abs(m.refresh - targetRefresh)
    var dist = dw * 1000 + dh * 1000 + dr
    if (dist < bestDist) {
      bestDist = dist
      best = m.value
    }
  }
  return best
}

// Parse `omarchy-powerprofiles-list --active-state` output into
// [{ name, label, active }]. Lines are "profile\t0|1".
function parseProfiles(raw) {
  var labels = {
    "power-saver": "Power Saver",
    "balanced": "Balanced",
    "performance": "Performance"
  }
  var profiles = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\t+/)
    var name = (parts[0] || "").trim()
    if (!name) continue
    profiles.push({
      name: name,
      label: labels[name] || name,
      active: (parts[1] || "").trim() === "1"
    })
  }
  return profiles
}

// Connector names (eDP-1, HDMI-A-1, …) are interpolated into a Lua string
// eval'd by hyprctl, so only a plain connector token may pass through.
function safeName(name) {
  return String(name || "").match(/^[A-Za-z0-9._-]+$/) ? String(name) : ""
}

// Read this widget's place in shell.json: the active section, its 0-based
// index, and the size of every section so the settings view can clamp the
// order stepper. Mirrors the shell's own layout shape; unknown or malformed
// input reports an empty placement instead of guessing.
function parseBarPlacement(raw, widgetId) {
  var sections = ["left", "center", "right"]
  var sizes = { left: 0, center: 0, right: 0 }
  var section = ""
  var index = -1
  try {
    var config = JSON.parse(String(raw || "{}"))
    var layout = (config && config.bar && config.bar.layout) || {}
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) list = []
      sizes[sections[s]] = list.length
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var id = entry && typeof entry === "object" ? String(entry.id || "") : String(entry || "")
        if (id === String(widgetId || "")) {
          section = sections[s]
          index = i
        }
      }
    }
  } catch (e) {
    return { section: "", index: -1, sizes: sizes }
  }
  return { section: section, index: index, sizes: sizes }
}

// `/proc/uptime` is "seconds.idle seconds.total". Only the first field matters
// and a malformed read must not turn into an uptime of zero.
function parseUptime(raw) {
  var seconds = parseFloat(String(raw || "").split(/\s+/)[0])
  return isFinite(seconds) && seconds > 0 ? seconds : 0
}

// Compact, stable uptime label: "12m", "20h 37m", "3d 4h".
function formatUptime(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  return minutes + "m"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseMonitors: parseMonitors,
    currentModeValue: currentModeValue,
    parseProfiles: parseProfiles,
    safeName: safeName,
    parseBarPlacement: parseBarPlacement,
    parseUptime: parseUptime,
    formatUptime: formatUptime
  }
}
