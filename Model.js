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
// Proton does not always use the ISO code. Diffing its 148 country codes
// against iso-codes' 249 ISO 3166-1 alpha-2 entries turns up exactly two that
// are not ISO:
//
//   UK  United Kingdom  -> ISO is GB. The pair U+1F1FA U+1F1F0 is not a
//                          defined flag sequence, so it renders as a
//                          placeholder box (the "? flag" this fixes).
//   XK  Kosovo          -> a user-assigned code, deliberately not in ISO.
//                          Unicode has no Kosovo flag at all, so no mapping
//                          can help and any pair we build renders as two
//                          boxed letters. Better to show nothing.
//
// Only the flag is remapped. The code shown in the row, and the one handed to
// `protonvpn connect --country`, stays exactly what Proton reported.
var FLAG_ALIASES = { "UK": "GB" }
var FLAGLESS_CODES = { "XK": true }

function countryFlagEmoji(code) {
  var text = String(code || "").trim().toUpperCase()
  if (FLAG_ALIASES[text] !== undefined) text = FLAG_ALIASES[text]
  if (FLAGLESS_CODES[text] === true) return ""
  if (!/^[A-Z]{2}$/.test(text)) return ""
  var base = 0x1F1E6
  var aCode = "A".charCodeAt(0)
  var first = base + (text.charCodeAt(0) - aCode)
  var second = base + (text.charCodeAt(1) - aCode)
  return String.fromCodePoint(first, second)
}

// `ip -4 -o addr show <iface>` prints e.g.:
//   4: proton0    inet 10.x.x.x/32 scope global proton0\ ...
function parseTunnelIp(raw) {
  var match = String(raw || "").match(/inet\s+(\d{1,3}(?:\.\d{1,3}){3})/)
  return match ? match[1] : ""
}

// Accepts IPv6 as well as IPv4. It used to take only IPv4, which meant that
// on a host whose lookup answered with an IPv6 address the panel sat on
// "Looking up…" forever - the request had in fact succeeded, and its result
// was being silently discarded here. The lookup now asks for IPv4 explicitly
// (see refreshPublicIp), so this is the fallback for a v6-only host rather
// than the usual path.
function parsePublicIp(raw) {
  var value = String(raw || "").trim()
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(value)) return value
  // Deliberately loose: enough to tell an address from an error page, without
  // reimplementing RFC 4291's sixteen forms.
  if (/^[0-9A-Fa-f:]{2,45}$/.test(value) && value.indexOf(":") !== -1) return value
  return ""
}

// --- Server intelligence -------------------------------------------------
//
// The CLI cannot report per-server detail at all. `protonvpn servers` prints
// a link to protonvpn.com and nothing else; `countries list` gives name+code
// only (its --help claims server counts, the 1.0.3 output has none); `cities
// list <CC>` gives city + a features column. Proton's own API is closed to
// us as well — api.protonvpn.ch/vpn/logicals answers 422 to a stale
// x-pm-appversion header and 401 Invalid access token to a current one.
//
// What the CLI does leave behind is the cache its daemon keeps refreshed
// while signed in:
//
//   $XDG_CACHE_HOME/Proton/VPN/serverlist.json   (~24MB, ~18k logical servers)
//
// Every entry there carries Name ("SE-JP#1"), Load, City, Tier, Status, a
// Features bitmask and Entry/ExitCountry; the top level carries MaxTier (the
// account's own tier) and LoadsExpirationTime. That is the whole feature.
//
// Both queries below are handed to jq rather than parsed here: the file is
// 24MB, which is not something to pull through QML's JS engine on every
// panel open, and jq chews it in ~0.3s. jq is a hard dependency of the
// `omarchy` package itself, so it is always present.
//
// Features is a bitmask — proton.vpn.session.servers.types.ServerFeatureEnum:
//   1 SECURE_CORE   2 TOR   4 P2P   8 STREAMING   16 IPV6
// jq has no bitwise operators, so the bits are tested arithmetically.

// Country roll-up: one row per country, cheap enough (~13KB for 148
// countries) to load whenever the picker opens. Status == 1 filters out
// servers Proton is reporting as down, so counts and the "best load" figure
// only ever describe servers you could actually reach.
var SERVER_STATS_QUERY =
  '((.LoadsExpirationTime // 0) | floor) as $exp' +
  // LoadsExpirationTime is the DAEMON'S refresh schedule, not a freshness
  // stamp: proton.vpn.session.servers.logicals sets it to now + ~15min
  // (LOADS_REFRESH_INTERVAL, +/-22%) and its refresher refetches once past
  // it. So it sits in the past routinely, in the ordinary gap before the
  // daemon gets to it, and permanently whenever the daemon is not refreshing
  // at all. Reporting that as "out of date" was a warning that meant nothing
  // and never went away. What is worth reporting is the loads' actual age,
  // which the panel only mentions once it is genuinely large.
  '| (if $exp > 0 then (((now - ($exp - 900)) / 60) | floor) else -1 end) as $age' +
  '| { loadsAgeMinutes: $age,' +
  '    maxTier: (.MaxTier // 0),' +
  '    countries: ([ .LogicalServers[] | select(.Status == 1) ]' +
  '      | group_by(.ExitCountry)' +
  '      | map(([ .[] | .City | select(. != null and . != "") ] | unique) as $cities |' +
  '            { code: .[0].ExitCountry,' +
  '              servers: length,' +
  '              cities: ($cities | length),' +
  // Naming the city outright is more use than the word "1 city".
  '              cityName: (if ($cities | length) == 1 then $cities[0] else "" end),' +
  '              load: ([ .[].Load ] | min),' +
  '              tier: ([ .[].Tier ] | min),' +
  '              p2p: any(.[]; ((.Features / 4) | floor) % 2 == 1),' +
  '              tor: any(.[]; ((.Features / 2) | floor) % 2 == 1),' +
  '              sc:  any(.[]; (.Features % 2) == 1) })) }'

// One country's cities, each with its own server list. Secure Core servers
// are grouped under their own pseudo-city rather than dropped: they exit in
// this country but enter through another (hence `entry`), and Proton leaves
// City null on them, which would otherwise bucket them under "Other".
//
// The per-city server list is capped at the 20 least-loaded. The cap is a UI
// decision, not a data one — Chicago alone has 875 servers and nobody scrolls
// that; `servers` still reports the true count so the row can say what the
// list is a subset of.
//
// Pinned servers are unioned in on top of that cap ($pins). Without it a pin
// would silently vanish the moment its server drifted out of the 20 least
// loaded — which is exactly when you'd want to still see the one you chose.
var COUNTRY_DETAIL_QUERY =
  'def bit($n): ((.Features / $n) | floor) % 2 == 1;' +
  '[ .LogicalServers[] | select(.Status == 1 and .ExitCountry == $cc) ]' +
  '| map({ name: .Name, load: .Load, tier: .Tier, entry: .EntryCountry,' +
  '        sc: (.Features % 2 == 1), p2p: bit(4), tor: bit(2),' +
  '        city: (if (.Features % 2 == 1) then "Secure Core" else (.City // "Other") end) })' +
  '| group_by(.city)' +
  '| map({ city: .[0].city,' +
  '        servers: length,' +
  '        load: ([ .[].load ] | min),' +
  '        p2p: any(.[]; .p2p),' +
  '        tor: any(.[]; .tor),' +
  '        sc: .[0].sc,' +
  '        list: ([ .[] | { name, load, tier, entry, sc } ]' +
  '                | (map(select((.name as $n | $pins | index($n)) != null))' +
  '                   + (sort_by(.load) | .[0:20]))' +
  '                | unique_by(.name) | sort_by(.load)) })' +
  '| sort_by(if .city == "Secure Core" then "" else .city end)'

// Both parsers return null rather than throwing on anything unexpected: a
// missing cache file (signed out, fresh install) makes jq exit non-zero with
// no stdout at all, and that has to read as "no enrichment available" so the
// picker can fall back to the plain CLI city list instead of breaking.
function parseServerStats(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return null }
  if (!parsed || !parsed.countries || parsed.countries.length === undefined) return null
  var byCountry = {}
  for (var i = 0; i < parsed.countries.length; i++) {
    var entry = parsed.countries[i]
    var code = String(entry.code || "")
    if (code !== "") byCountry[code] = entry
  }
  var age = Number(parsed.loadsAgeMinutes)
  return {
    loadsAgeMinutes: isFinite(age) ? age : -1,
    maxTier: Number(parsed.maxTier) || 0,
    byCountry: byCountry
  }
}

function parseCountryDetail(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return null }
  if (!parsed || parsed.length === undefined) return null
  return parsed
}

// "5925" reads as noise in a row that also carries a load figure and a city
// count, and Proton's big countries are all four digits.
function formatServerCount(count) {
  var n = Number(count)
  if (!isFinite(n) || n <= 0) return ""
  if (n < 1000) return String(n)
  return (Math.round(n / 100) / 10) + "k"
}

// The place half of a country's subtitle. A country with exactly one city is
// named outright - "Athens" tells you where you land, "1 city" does not.
function describeCountry(stats) {
  if (!stats) return ""
  var cities = Number(stats.cities) || 0
  if (cities === 1) {
    var name = String(stats.cityName || "")
    return name !== "" ? name : "1 city"
  }
  if (cities > 1) return cities + " cities"
  return ""
}

// Semantic tokens, not display text: the panel maps these to glyphs and
// tooltips, which keeps font decisions out of here. Order matches how
// Proton's own clients list the features.
//
// Secure Core is deliberately omitted at country level - every country with
// any Secure Core route would carry the badge, which says nothing; it is
// shown on the Secure Core city row instead, where it is the whole point.
function featureBadges(entry) {
  if (!entry) return []
  var badges = []
  if (entry.p2p === true) badges.push("p2p")
  if (entry.tor === true) badges.push("tor")
  return badges
}

// Loads refresh about every 15 minutes, so anything inside an hour is normal
// operation and not worth a word. An hour past that is four missed refreshes
// — by then the daemon has genuinely stopped updating them (signed out, or
// asleep), and the numbers are worth a caveat.
function loadAgeNotice(minutes) {
  var value = Number(minutes)
  if (!isFinite(value) || value < 75) return ""
  if (value < 120) return "Server loads are about an hour old"
  var hours = Math.round(value / 60)
  if (hours < 24) return "Server loads are about " + hours + " hours old"
  var days = Math.round(hours / 24)
  return "Server loads are " + (days === 1 ? "about a day old" : ("about " + days + " days old"))
}

// --- Keyring health ------------------------------------------------------

// Why a VPN widget knows anything about gnome-keyring.
//
// python-proton-keyring-linux stores the whole session as one JSON string
// (`_set_item` is json.dumps() straight into the Secret Service). That string
// embeds the VPN certificate's PEM blocks, so it is full of escaped newlines.
// gnome-keyring's plain-text format — what you get when the keyring has no
// password — writes a secret out unescaped but unescapes \n when reading it
// back, so once the session has been read and the collection rewritten, those
// escapes have become real newlines and the file's INI structure is gone. The
// daemon then fails to parse it on its next start and discards the entire
// collection, the app finds no session, and the user is asked to sign in
// again — forever, because the fresh sign-in is written straight back into
// the same passwordless keyring.
//
// See https://discourse.gnome.org/t/possible-bug-or-feature-storing-getting-data-keyring-protected-vs-unprotected-keyring/20312
// The read-side `.replace("\n", "\\n")` workaround already in
// secretservice_backend.py cannot help: by the time it runs the file on disk
// is already broken and every item in it has been dropped.
//
// None of that is fixable here — the widget never touches the keyring, it
// only shells out to the `protonvpn` CLI. What it can do is stop saying
// "Sign in to ProtonVPN" as though nothing were wrong, which is what sends
// the user back around the loop without ever learning why.

// Prints "<verdict> <dir>": ok | plaintext | corrupt, plus the directory it
// looked in, so a wrong answer can be told apart from a wrong path.
//
// The directory is resolved in the shell rather than passed in, because the
// process inherits the real session environment and Quickshell.env() does not
// necessarily see the same XDG variables.
// Deliberately prints no part of any secret, only a verdict.
//
// A passwordless keyring is plain text and starts with a literal `[keyring]`
// line; an encrypted one starts with the binary "GnomeKeyring" magic, so the
// first line alone separates them. Corruption is detected structurally: every
// line of an intact file is a `[section]`, a `key=value`, or blank, so any
// line that is none of those is a secret that has spilled across the file.
var KEYRING_PROBE = [
  'dir="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"; out=ok',
  '[ -d "$dir" ] || { echo "ok $dir"; exit 0; }',
  'for f in "$dir"/*.keyring; do',
  '  [ -f "$f" ] || continue',
  '  read -r first < "$f" || continue',
  '  [ "$first" = "[keyring]" ] || continue',
  '  grep -q "on .Proton." "$f" || continue',
  '  out=plaintext',
  '  if grep -qvE "^\\[[^]]*\\]$|^[A-Za-z][A-Za-z0-9_-]*=|^$" "$f"; then out=corrupt; break; fi',
  'done',
  'echo "$out $dir"'
].join("\n")

// Kept short on purpose: this renders as a wrapped caption in a bar popup,
// not a bug report. The one thing the user can actually act on — put a
// password on the keyring — is the last clause of each.
function keyringNotice(health) {
  if (health === "corrupt")
    return "Your keyring has no password, so ProtonVPN loses this sign-in on every restart — its keyring file is already damaged. Fix it by setting a password on your login keyring."
  if (health === "plaintext")
    return "Your keyring has no password, so ProtonVPN can lose this sign-in when you restart. Setting a password on your login keyring prevents it."
  return ""
}

function isLocked(tier, maxTier) {
  return (Number(tier) || 0) > (Number(maxTier) || 0)
}

// --- Recents and pins ----------------------------------------------------
//
// Persisted next to the other Omarchy plugin state, in the same shape and by
// the same means the clipboard plugin uses for its history (a FileView with
// atomicWrites). Kept pure here so the merge/dedupe rules are testable
// outside Quickshell, like the parsers above.

// One stable identity per connectable thing, so a repeat connection moves the
// existing entry to the front instead of stacking duplicates.
function recentKey(entry) {
  if (!entry) return ""
  var kind = String(entry.kind || "")
  if (kind === "server") return "s:" + String(entry.name || "")
  if (kind === "city") return "y:" + String(entry.code || "") + "/" + String(entry.city || "")
  if (kind === "country") return "c:" + String(entry.code || "")
  return ""
}

function addRecent(list, entry, limit) {
  var key = recentKey(entry)
  if (key === "") return Array.isArray(list) ? list : []
  var max = Number(limit) > 0 ? Number(limit) : 20
  var result = [entry]
  var source = Array.isArray(list) ? list : []
  for (var i = 0; i < source.length && result.length < max; i++) {
    if (recentKey(source[i]) !== key) result.push(source[i])
  }
  return result
}

// Pins are plain string lists (country codes, server names). Toggling returns
// a NEW array rather than mutating: QML only re-evaluates bindings when the
// property is reassigned, so in-place mutation would leave the list stale.
function toggleInList(list, value) {
  var text = String(value || "")
  if (text === "") return Array.isArray(list) ? list : []
  var source = Array.isArray(list) ? list : []
  var result = []
  var found = false
  for (var i = 0; i < source.length; i++) {
    if (String(source[i]) === text) { found = true; continue }
    result.push(String(source[i]))
  }
  if (!found) result.unshift(text)
  return result
}

function listContains(list, value) {
  if (!Array.isArray(list)) return false
  var text = String(value || "")
  for (var i = 0; i < list.length; i++) if (String(list[i]) === text) return true
  return false
}

// Tolerant of anything: a missing file, a truncated write, or state written
// by a future version. Anything unreadable degrades to empty rather than
// throwing, because none of this is worth breaking the panel over.
function parseState(raw) {
  // Must carry EVERY key the success path returns. It did not carry
  // `countries`, so on a fresh install (no file -> onLoadFailed -> "") the
  // caller's `parsed.countries.length` threw before it could set
  // stateLoaded, and saveState()'s `if (!stateLoaded) return` then silenced
  // every write for the rest of the session - pins, recents and the country
  // cache all lost, the file never created, repeating every launch.
  var empty = { recent: [], pinnedCountries: [], pinnedServers: [],
                countries: [], countriesCachedAt: 0 }
  var text = String(raw || "").trim()
  if (text === "") return empty
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return empty }
  if (!parsed || typeof parsed !== "object") return empty
  var recent = []
  if (parsed.recent && parsed.recent.length !== undefined) {
    for (var i = 0; i < parsed.recent.length; i++) {
      var entry = parsed.recent[i]
      if (entry && recentKey(entry) !== "") recent.push(entry)
    }
  }
  return {
    recent: recent,
    pinnedCountries: sanitizeStringList(parsed.pinnedCountries),
    pinnedServers: sanitizeStringList(parsed.pinnedServers),
    countries: sanitizeCountries(parsed.countries),
    countriesCachedAt: Number(parsed.countriesCachedAt) || 0
  }
}

// The country list is cached so the picker has something to show the instant
// it opens. `protonvpn countries list` is a network round-trip that takes
// seconds, and it used to be the only source - so every fresh shell meant
// staring at "Loading countries..." before anything appeared.
function sanitizeCountries(value) {
  var result = []
  if (!value || value.length === undefined) return result
  for (var i = 0; i < value.length; i++) {
    var entry = value[i]
    if (!entry) continue
    var name = String(entry.name || "")
    var code = String(entry.code || "")
    if (name !== "" && /^[A-Za-z]{2}$/.test(code)) result.push({ name: name, code: code })
  }
  return result
}

function sanitizeStringList(value) {
  var result = []
  if (!value || value.length === undefined) return result
  for (var i = 0; i < value.length; i++) {
    var text = String(value[i] || "")
    if (text !== "") result.push(text)
  }
  return result
}

// A recent entry's own label, so the list can render without re-deriving it
// from data that may not be loaded yet.
function describeRecent(entry) {
  if (!entry) return ""
  var kind = String(entry.kind || "")
  if (kind === "server") return String(entry.name || "")
  if (kind === "city") return String(entry.city || "")
  return String(entry.label || entry.code || "")
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
    parseTunnelIp: parseTunnelIp,
    parsePublicIp: parsePublicIp,
    SERVER_STATS_QUERY: SERVER_STATS_QUERY,
    COUNTRY_DETAIL_QUERY: COUNTRY_DETAIL_QUERY,
    parseServerStats: parseServerStats,
    parseCountryDetail: parseCountryDetail,
    formatServerCount: formatServerCount,
    describeCountry: describeCountry,
    featureBadges: featureBadges,
    loadAgeNotice: loadAgeNotice,
    KEYRING_PROBE: KEYRING_PROBE,
    keyringNotice: keyringNotice,
    recentKey: recentKey,
    addRecent: addRecent,
    toggleInList: toggleInList,
    listContains: listContains,
    parseState: parseState,
    describeRecent: describeRecent,
    isLocked: isLocked
  }
}
