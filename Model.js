// Pure parsing helpers for the ProtonVPN CLI. Kept dependency-free so they
// stay unit-testable outside Quickshell (same convention as the Tailscale
// plugin's Model.js).

// `protonvpn status` output, observed directly on this machine:
//
// Disconnected:
//   Status: Disconnected
//
// Connected:
//   Status: Connected
//   Server: LT#24 in Vilnius, Lithuania
//   Load: 16%
//   Protocol: wireguard
function parseStatus(raw) {
  var text = String(raw || "")
  var lines = text.split(/\r?\n/)
  var fields = {}

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var match = line.match(/^\s*([A-Za-z ]+?)\s*:\s*(.*)$/)
    if (!match) continue
    var key = match[1].trim().toLowerCase()
    var value = match[2].trim()
    if (key !== "") fields[key] = value
  }

  var statusValue = String(fields["status"] || "").toLowerCase()
  var connected = statusValue === "connected"

  if (statusValue === "") {
    // Nothing recognizable in the output — surface as an error rather than
    // silently reporting "disconnected".
    return { ok: false, message: "Could not read ProtonVPN status" }
  }

  return {
    ok: true,
    connected: connected,
    server: String(fields["server"] || ""),
    load: String(fields["load"] || ""),
    protocol: String(fields["protocol"] || "")
  }
}

// `protonvpn info` prints `Account: '<username>'` and exits 0 when signed
// in — but it ALSO exits 0 when signed OUT, printing the literal placeholder
// `Account: 'None'` (confirmed directly against the real CLI: exit code 0
// either way). So exit code alone can't tell the caller whether someone is
// actually signed in; treat the 'None' placeholder the same as no account.
function parseAccountName(raw) {
  var text = String(raw || "")
  var match = text.match(/Account:\s*'([^']*)'/)
  var name = match ? match[1] : ""
  return name === "None" ? "" : name
}

// Server field looks like "LT#24 in Vilnius, Lithuania" — split off the
// "City, Country" part after " in " for a shorter subtitle.
function serverLocation(server) {
  var text = String(server || "")
  var idx = text.indexOf(" in ")
  return idx === -1 ? text : text.substring(idx + 4).trim()
}

function serverName(server) {
  var text = String(server || "")
  var idx = text.indexOf(" in ")
  return idx === -1 ? text : text.substring(0, idx).trim()
}

function elideStatus(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  return value.length > 140 ? value.substring(0, 137) + "…" : value
}

// `protonvpn status` calls out to Proton's API for the live server list
// whenever a connection is active (to report current Load%), and `info`
// can do the same to validate the session — so both commands can legitimately
// hit a network blip, not just query a local daemon. The CLI's own error
// handler (proton/vpn/cli/__init__.py) catches that as
// `TimeoutError`/`ProtonAPINotReachable` and prints exactly this message
// with a non-zero exit. That, and a bare bug/unexpected-error exit, are
// transient — never proof the account is signed out or the tunnel dropped.
// Only a message the CLI itself frames as an auth problem should be trusted
// as a real "needs login" signal.
function classifyCliFailure(text) {
  var value = String(text || "")
  if (/network connectivity issues|ProtonAPINotReachable|Failed to establish|Temporary failure in name resolution|Connection timed out|Name or service not known/i.test(value)) return "network"
  if (/not logged in|please sign in|please log in|authentication required|invalid session|session.*expired|AuthenticationRequiredError/i.test(value)) return "authRequired"
  return "unknown"
}

// `protonvpn countries list` prints a tabulate table:
//   Country                           Code
//   --------------------------------  ------
//   Afghanistan                       AF
function parseCountries(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var result = []
  var started = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^-{3,}\s+-{2,}\s*$/.test(line)) { started = true; continue }
    if (!started) continue
    if (/^\s*$/.test(line)) continue
    var match = line.match(/^(.{2,}?)\s{2,}([A-Za-z]{2})\s*$/)
    if (!match) continue
    result.push({ name: match[1].trim(), code: match[2].trim() })
  }
  return result
}

// Builds a flag emoji from an ISO 3166-1 alpha-2 code (what `protonvpn
// countries list` prints) with no image assets: each letter maps to a
// Regional Indicator Symbol codepoint (U+1F1E6 = 'A' ... U+1F1FF = 'Z'), and
// a consecutive pair of those is rendered as a single flag by fonts that
// support the sequence (Noto Color Emoji, which ships as the default emoji
// font on Omarchy, does). Returns "" for anything that isn't exactly two
// ASCII letters rather than emit a broken/mismatched glyph pair.
function countryFlagEmoji(code) {
  var text = String(code || "").trim().toUpperCase()
  if (!/^[A-Z]{2}$/.test(text)) return ""
  var base = 0x1F1E6
  var aCode = "A".charCodeAt(0)
  var first = base + (text.charCodeAt(0) - aCode)
  var second = base + (text.charCodeAt(1) - aCode)
  return String.fromCodePoint(first, second)
}

// `protonvpn cities list <country>` prints a similar table:
//   Cities in United States:
//   City            Features
//   --------------  ----------
//   Ashburn         P2P
function parseCities(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var result = []
  var started = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^-{3,}\s+-{2,}\s*$/.test(line)) { started = true; continue }
    if (!started) continue
    if (/^\s*$/.test(line)) continue
    var match = line.match(/^(.{2,}?)\s{2,}(.*)$/)
    if (!match) continue
    result.push({ name: match[1].trim(), features: match[2].trim() })
  }
  return result
}

// `ip -4 -o addr show <iface>` prints e.g.:
//   4: proton0    inet 10.2.0.2/32 scope global proton0\ ...
function parseTunnelIp(raw) {
  var match = String(raw || "").match(/inet\s+(\d{1,3}(?:\.\d{1,3}){3})/)
  return match ? match[1] : ""
}

function parsePublicIp(raw) {
  var value = String(raw || "").trim()
  return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(value) ? value : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    parseStatus: parseStatus,
    parseAccountName: parseAccountName,
    serverLocation: serverLocation,
    serverName: serverName,
    elideStatus: elideStatus,
    classifyCliFailure: classifyCliFailure,
    parseCountries: parseCountries,
    countryFlagEmoji: countryFlagEmoji,
    parseCities: parseCities,
    parseTunnelIp: parseTunnelIp,
    parsePublicIp: parsePublicIp
  }
}
