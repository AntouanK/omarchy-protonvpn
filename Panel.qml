import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "antouank.protonvpn"
  ipcTarget: "antouank.protonvpn"
  manageIpc: false

  // Cursor targets: the connect/disconnect switch on the hero, the location
  // picker toggle + its country list, and the sign-in/sign-out row. Same
  // "focusSection" idea as the Tailscale panel, just a smaller state machine.
  property string focusSection: "header"
  property bool cursorActive: false

  // Feature 1: country/city picker.
  property bool locationPickerOpen: false
  property string locationQuery: ""
  property int locationIndex: 0
  property string expandedCountryCode: ""
  // "<CC>/<city>", because city names are only unique within a country.
  property string expandedCityKey: ""
  // "all" browses every country; "recent" lists what you last connected to.
  property string locationTab: "all"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && vpn.installed
  readonly property bool authHasCursor: cursorActive && focusSection === "auth" && vpn.installed
  readonly property bool locationsToggleHasCursor: cursorActive && focusSection === "locationsToggle" && vpn.installed
  readonly property string toggleHint: vpn.needsLogin ? "Sign in to connect" : (vpn.active ? "Turn ProtonVPN off" : "Turn ProtonVPN on")
  readonly property string heroMeta: {
    if (vpn.needsLogin) return "Needs sign-in"
    if (vpn.connecting) return "Connecting…"
    if (vpn.active) return vpn.serverText !== "" ? vpn.serverLocation(vpn.serverText) : "Connected"
    return "Disconnected"
  }
  readonly property string authLabel: vpn.needsLogin ? "Sign in to ProtonVPN" : "Sign out of ProtonVPN"
  // The detail line under authLabel must never itself read like an action —
  // "Signed in as X" sitting right under an action button reading "Sign out
  // of ProtonVPN" was ambiguous (user report: looked like two competing
  // actions). Signed-in state is now just the bare account name, with no
  // verb at all, so there's only one thing on this row that reads as a
  // button.
  readonly property string authDetail: vpn.needsLogin ? "Opens a terminal for your username and password" : (vpn.accountName !== "" ? vpn.accountName : "Account active")
  // "148 countries · 194 cities", or just the country count until the server
  // cache has been read. Empty while there is genuinely nothing known yet, so
  // the header does not flash a zero on the way up.
  readonly property string locationsSummary: {
    var countries = vpn.countries ? vpn.countries.length : 0
    if (countries === 0) return ""
    var parts = [countries + " countries"]
    if (vpn.statsAvailable) {
      var cities = 0
      for (var code in vpn.countryStats) cities += Number(vpn.countryStats[code].cities) || 0
      if (cities > 0) parts.push(cities + " cities")
    }
    return parts.join(" · ")
  }

  readonly property var filteredCountries: filterCountries()
  // The picker is a tree (country > city > server) rendered as one flat list,
  // which is what lets a single ListView virtualize the whole thing and what
  // lets the keyboard cursor stay a single integer index. Rebuilt whenever
  // the filter, either expansion, or the underlying service data changes.
  readonly property var locationRows: buildLocationRows()

  function filterCountries() {
    var query = String(locationQuery || "").trim().toLowerCase()
    var matched = []
    if (query === "") {
      matched = vpn.countries
    } else {
      for (var i = 0; i < vpn.countries.length; i++) {
        var country = vpn.countries[i]
        var label = (String(country.name || "") + " " + String(country.code || "")).toLowerCase()
        if (label.indexOf(query) !== -1) matched.push(country)
      }
    }
    return pinnedFirst(matched)
  }

  // Same rule one level down: a pinned server heads its city's list, with
  // the rest still in load order behind it.
  function pinnedServersFirst(list) {
    if (!vpn.pinnedServers || vpn.pinnedServers.length === 0) return list
    var pinned = []
    var rest = []
    for (var i = 0; i < list.length; i++) {
      if (vpn.isServerPinned(String(list[i].name || ""))) pinned.push(list[i])
      else rest.push(list[i])
    }
    return pinned.concat(rest)
  }

  // Pins float to the top while everything keeps its existing (alphabetical)
  // order within each group, so pinning something does not otherwise
  // reshuffle the list under you.
  function pinnedFirst(list) {
    if (!vpn.pinnedCountries || vpn.pinnedCountries.length === 0) return list
    var pinned = []
    var rest = []
    for (var i = 0; i < list.length; i++) {
      if (vpn.isCountryPinned(String(list[i].code || ""))) pinned.push(list[i])
      else rest.push(list[i])
    }
    return pinned.concat(rest)
  }

  function buildLocationRows() {
    if (locationTab === "recent") return buildRecentRows()
    // Signed out the picker shows "Sign in to browse countries" instead of
    // the list. The rows have to be absent, not merely hidden: the keyboard
    // cursor walks locationRows, so leaving a cached 148-country list in it
    // let `j` disappear into rows nothing was drawing, and put ~148
    // keypresses between the toggle and the sign-in button below it.
    if (vpn.needsLogin || vpn.countriesAuthRequired) return []
    var rows = []
    var list = filteredCountries
    for (var i = 0; i < list.length; i++) {
      var country = list[i]
      var code = String(country.code || "")
      var stats = vpn.statsAvailable && vpn.countryStats ? vpn.countryStats[code] : null
      var countryOpen = expandedCountryCode === code
      rows.push({
        key: "c:" + code,
        kind: "country",
        depth: 0,
        code: code,
        city: "",
        server: null,
        label: String(country.name || "Unknown"),
        // Empty when the server cache is unavailable, which collapses the row
        // back to exactly what it showed before this feature: name and code.
        detail: vpn.describeCountry(stats),
        count: stats ? Number(stats.servers) : -1,
        via: "",
        badges: vpn.featureBadges(stats),
        stats: stats,
        expanded: countryOpen,
        pinned: vpn.isCountryPinned(code),
        locked: false,
        text: ""
      })
      if (!countryOpen) continue

      var detail = vpn.detailByCountry ? vpn.detailByCountry[code] : undefined
      if (detail === undefined) {
        rows.push(statusRow(1, "Loading servers…"))
        continue
      }
      if (detail === null) {
        // jq could not read the cache for this country. The country row above
        // is still connectable, so this is a note, not a failure.
        rows.push(statusRow(1, "Server details unavailable"))
        continue
      }
      if (detail.length === 0) {
        rows.push(statusRow(1, "No cities listed."))
        continue
      }

      for (var j = 0; j < detail.length; j++) {
        var city = detail[j]
        var cityName = String(city.city || "")
        var cityKey = code + "/" + cityName
        var cityOpen = expandedCityKey === cityKey
        var cityBadges = vpn.featureBadges(city)
        if (city.sc === true) cityBadges = ["sc"]
        rows.push({
          key: "y:" + code + "/" + cityName,
          kind: "city",
          depth: 1,
          code: code,
          city: cityName,
          server: null,
          label: cityName,
          detail: "",
          count: Number(city.servers),
          via: "",
          badges: cityBadges,
          stats: city,
          expanded: cityOpen,
          locked: false,
          text: ""
        })
        if (!cityOpen) continue

        var servers = pinnedServersFirst(city.list || [])
        for (var k = 0; k < servers.length; k++) {
          var server = servers[k]
          // A server the account cannot use gets a lock. Its opposite needs no
          // badge: on a free account everything else carries one, so the
          // absence is already the signal.
          var badges = []
          if (vpn.isLocked(server.tier)) badges.push("plus")
          rows.push({
            key: "s:" + code + "/" + cityName + "/" + String(server.name || ""),
            kind: "server",
            depth: 2,
            code: code,
            city: cityName,
            server: server,
            label: String(server.name || ""),
            detail: "",
            count: -1,
            // Secure Core's whole point is which country you enter through,
            // so that is the one thing a Secure Core server row has to say.
            via: server.sc === true ? String(server.entry || "") : "",
            badges: badges,
            stats: null,
            expanded: false,
            pinned: vpn.isServerPinned(String(server.name || "")),
            locked: vpn.isLocked(server.tier),
            text: ""
          })
        }
        // Say what the list is a subset of - see the cap note in Model.js.
        if (Number(city.servers) > servers.length) {
          rows.push(statusRow(2, "Showing the " + servers.length + " least-loaded of " + city.servers))
        }
      }
    }
    return rows
  }

  // The RECENT tab. Entries are whatever you actually connected to, at the
  // level you connected at - a country, a city, or one named server - so each
  // row reconnects to exactly that thing rather than to some rounded-off
  // version of it.
  function buildRecentRows() {
    var rows = []
    var list = vpn.recentConnections || []
    if (list.length === 0) {
      rows.push(statusRow(0, "Nothing yet — places you connect to appear here."))
      return rows
    }
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      var kind = String(entry.kind || "")
      var code = String(entry.code || "")
      var stats = kind === "country" && vpn.statsAvailable && vpn.countryStats ? vpn.countryStats[code] : null
      rows.push({
        key: "r:" + vpn.recentKey(entry),
        kind: "recent",
        entryKind: kind,
        depth: 0,
        code: code,
        city: String(entry.city || ""),
        server: kind === "server" ? { name: String(entry.name || "") } : null,
        label: vpn.describeRecent(entry),
        detail: recentContext(entry),
        count: -1,
        via: "",
        badges: [],
        stats: stats,
        expanded: false,
        locked: false,
        text: ""
      })
    }
    return rows
  }

  // Where a recent entry actually was, since a bare city or server name does
  // not say which country it belongs to.
  function recentContext(entry) {
    var kind = String(entry.kind || "")
    var code = String(entry.code || "")
    var city = String(entry.city || "")
    if (kind === "server") return city !== "" ? (city + ", " + code) : code
    if (kind === "city") return code
    return ""
  }

  function statusRow(depth, text) {
    return { key: "t:" + depth + ":" + text, kind: "status", depth: depth, text: text,
             entryKind: "", code: "", city: "", server: null, count: -1, via: "",
             label: "", detail: "", badges: [], stats: null, expanded: false, locked: false }
  }

  function rowAt(index) {
    if (index < 0 || index >= locationRows.length) return null
    return locationRows[index]
  }

  function isSelectable(index) {
    var row = rowAt(index)
    return row !== null && row.kind !== "status"
  }

  // Status rows are captions, not targets, so the cursor steps over them
  // instead of landing on a "Loading servers…" line that does nothing.
  function nextSelectable(from, step) {
    var index = from
    for (var guard = 0; guard < locationRows.length; guard++) {
      index += step
      if (index < 0 || index >= locationRows.length) return -1
      if (isSelectable(index)) return index
    }
    return -1
  }

  function firstSelectable() {
    return isSelectable(0) ? 0 : nextSelectable(0, 1)
  }

  function ensureCursor() {
    if (focusSection === "locations" && locationRows.length === 0) focusSection = "locationsToggle"
    if (focusSection === "locations") {
      locationIndex = Math.max(0, Math.min(locationIndex, locationRows.length - 1))
      // An expand/collapse can leave the cursor on what is now a status row.
      if (!isSelectable(locationIndex)) {
        var moved = nextSelectable(locationIndex, 1)
        if (moved < 0) moved = nextSelectable(locationIndex, -1)
        if (moved < 0) focusSection = "locationsToggle"
        else locationIndex = moved
      }
    }
    if (focusSection !== "header" && focusSection !== "auth" && focusSection !== "locationsToggle" && focusSection !== "locations") focusSection = "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    // Left/right expands and collapses the row under the cursor, so the tree
    // is reachable without the mouse - the chevron is a mouse target only.
    if (dx !== 0) {
      // The tab strip is a ButtonGroup with no cursor section of its own, so
      // left/right on the row directly above it switches tabs. Without this
      // the Recent tab was reachable only with the mouse, in a panel whose
      // whole point is that it is keyboard-driven.
      if (focusSection === "locationsToggle" && locationPickerOpen) {
        selectTab(dx > 0 ? "recent" : "all")
        return
      }
      if (focusSection !== "locations") return
      var target = rowAt(locationIndex)
      if (!target) return
      if (dx > 0) expandRow(target)
      else collapseRow(target)
      ensureCursor()
      scrollCursorIntoView()
      return
    }
    if (dy === 0) return
    var hasRows = locationPickerOpen && locationRows.length > 0
    if (focusSection === "header") {
      if (dy > 0) focusSection = "locationsToggle"
    } else if (focusSection === "locationsToggle") {
      if (dy < 0) focusSection = "header"
      else if (hasRows) {
        var first = firstSelectable()
        if (first < 0) focusSection = "auth"
        else { focusSection = "locations"; locationIndex = first }
      }
      else focusSection = "auth"
    } else if (focusSection === "locations") {
      var next = nextSelectable(locationIndex, dy < 0 ? -1 : 1)
      if (next >= 0) locationIndex = next
      else focusSection = dy < 0 ? "locationsToggle" : "auth"
    } else if (focusSection === "auth") {
      if (dy < 0) {
        if (!hasRows) focusSection = "locationsToggle"
        else {
          var last = isSelectable(locationRows.length - 1)
            ? locationRows.length - 1
            : nextSelectable(locationRows.length - 1, -1)
          if (last < 0) focusSection = "locationsToggle"
          else { focusSection = "locations"; locationIndex = last }
        }
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") vpn.toggleConnection()
    else if (focusSection === "auth") activateAuth()
    else if (focusSection === "locationsToggle") toggleLocationPicker()
    else if (focusSection === "locations") activateSelectedLocation()
  }

  function activateAuth() {
    // Mirrors the mouse path's `enabled: !vpn.busy` on the row's MouseArea -
    // without this, the keyboard cursor could fire signOut()/signIn() while
    // a connect/disconnect is still in flight, racing it.
    if (vpn.busy) return
    if (vpn.needsLogin) vpn.signIn()
    else vpn.signOut()
  }

  function selectTab(tab) {
    if (locationTab === tab) return
    locationTab = tab
    // The two tabs are different lists; an index from one means nothing in
    // the other.
    locationIndex = 0
    disarmPointer()
    ensureCursor()
    if (locationsList) locationsList.positionViewAtBeginning()
  }

  function toggleLocationPicker() {
    locationPickerOpen = !locationPickerOpen
    if (!locationPickerOpen) {
      expandedCountryCode = ""
      expandedCityKey = ""
    }
    if (locationPickerOpen) {
      // Shows whatever is cached straight away and only refetches if that is
      // missing or old, instead of making you wait on the network every time.
      vpn.refreshCountries()
      // Cheap (~13KB of jq output) and the load figures it carries go stale,
      // so it is re-read on open rather than kept for the panel's life.
      vpn.loadServerStats()
    }
  }

  function selectedRow() {
    return rowAt(locationIndex)
  }

  function activateSelectedLocation() {
    activateRow(selectedRow())
  }

  // Clicking any row connects to what that row names: the country's fastest
  // server, the city's fastest, or one specific server.
  function activateRow(row) {
    if (!row) return
    if (row.kind === "recent") {
      if (row.entryKind === "server") vpn.connectServer(row.server ? row.server.name : "", row.code, row.city)
      else if (row.entryKind === "city") vpn.connectLocation(row.code, row.city)
      else vpn.connectLocation(row.code, "")
      return
    }
    if (row.kind === "server") {
      if (row.locked === true) return
      vpn.connectServer(row.server ? row.server.name : "", row.code, row.city)
      return
    }
    if (row.kind === "city") {
      // "Secure Core" and "Other" are both buckets the detail query invents -
      // the first for servers Proton leaves City-less, the second for any
      // other null City. Neither is a city the CLI has ever heard of, so
      // `--city Secure Core` / `--city Other` just errors. Fall back to the
      // country, which is what those servers actually are.
      if (isSyntheticCity(row)) vpn.connectLocation(row.code, "")
      else vpn.connectLocation(row.code, row.city)
      return
    }
    if (row.kind === "country") vpn.connectLocation(row.code, "")
  }

  // Only countries and servers pin — a city is not something you would keep
  // at the top on its own, and the user asked for these two levels.
  function canPin(row) {
    if (!row) return false
    if (row.kind === "country") return true
    return row.kind === "server" && row.server !== null
  }

  function togglePin(row) {
    if (!canPin(row)) return
    disarmPointer()
    if (row.kind === "country") vpn.toggleCountryPin(row.code)
    else vpn.toggleServerPin(row.server ? row.server.name : "")
  }

  function togglePinAtCursor() {
    if (focusSection !== "locations") return
    togglePin(rowAt(locationIndex))
  }

  // Buckets invented by COUNTRY_DETAIL_QUERY rather than reported by Proton.
  function isSyntheticCity(row) {
    if (!row) return false
    if (row.stats && row.stats.sc === true) return true
    return String(row.city || "") === "Other"
  }

  function toggleExpanded(row) {
    if (!row) return
    if (row.expanded === true) collapseRow(row)
    else expandRow(row)
  }

  function expandRow(row) {
    if (!row) return
    disarmPointer()
    if (row.kind === "country") {
      if (expandedCountryCode !== row.code) {
        expandedCountryCode = row.code
        // Collapsing the previous country leaves a stale city expansion behind.
        expandedCityKey = ""
        vpn.loadCountryDetail(row.code)
      }
    } else if (row.kind === "city") {
      expandedCityKey = row.code + "/" + row.city
    }
  }

  function collapseRow(row) {
    if (!row) return
    disarmPointer()
    if (row.kind === "server") {
      // Nothing to collapse on a leaf - step out to its city instead.
      expandedCityKey = ""
    } else if (row.kind === "city") {
      if (expandedCityKey === row.code + "/" + row.city) expandedCityKey = ""
      else { expandedCountryCode = ""; expandedCityKey = "" }
    } else if (row.kind === "country") {
      expandedCountryCode = ""
      expandedCityKey = ""
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setAuthCursor() {
    cursorActive = true
    focusSection = "auth"
  }

  function setLocationsToggleCursor() {
    cursorActive = true
    focusSection = "locationsToggle"
  }

  // Hover moves the cursor, but must not scroll: scrolling under a stationary
  // pointer puts a different row beneath it, which fires another hover, which
  // scrolls again. That feedback loop is the "list starts scrolling on its
  // own at the edges" bug — reported on the old build, and it would have
  // survived into this one. Keyboard movement scrolls; the pointer never does.
  function setLocationCursor(index) {
    cursorActive = true
    focusSection = "locations"
    locationIndex = index
  }

  // The other half of the same problem: even without scrolling, expanding a
  // row moves its neighbours under a stationary pointer and Qt sends hover
  // events for that. PointerMoveGate is the shell's own filter for exactly
  // this (see Ui/PointerMoveGate.qml, and the clipboard and menu plugins) —
  // a hover only counts once the pointer has actually travelled.
  function setLocationCursorFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    setLocationCursor(index)
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  // Load colour.
  //
  // This deliberately does NOT blend between the theme's foreground and
  // urgent colours, which was the first attempt. On a near-monochrome theme
  // those two endpoints are almost the same colour - measured on Venice From
  // Above they are #492924 and #706548, two dark browns only DeltaE 28 apart
  // in total, so each of four bands differed by DeltaE ~9. That is less than
  // the panel's own dim-versus-normal text difference, at caption size on a
  // 26x3px bar: the ramp was invisible, and no threshold tuning could fix it
  // because the endpoints themselves carry no contrast.
  //
  // So the bands are fixed hues, the one thing a reader interprets without a
  // legend. Two sets, chosen for contrast against the surface they sit on
  // (>= 4:1 on a light popup, and the mirror for dark), because a palette
  // legible on parchment is unreadable on near-black.
  readonly property bool lightSurface: {
    var surface = Color.popups.background
    return (0.2126 * surface.r + 0.7152 * surface.g + 0.0722 * surface.b) > 0.5
  }
  readonly property var loadPalette: lightSurface
    ? ["#1B7F3B", "#A66A00", "#B4531F", "#B3261E"]
    : ["#6FCF8B", "#E0B252", "#E08A4C", "#E2645C"]

  // Thresholds stay absolute and honest - quiet / moderate / busy / heavy -
  // rather than being stretched to spread the visible rows evenly across all
  // four colours. Most country rows really are green: the row shows the
  // LEAST loaded server in that country, and it genuinely is barely used.
  // Re-scaling so that a 30%-loaded server turned red would have made the
  // list look more colourful by overstating what the number means.
  function loadTone(load) {
    if (load < 0) return dim
    if (load < 25) return loadPalette[0]
    if (load < 50) return loadPalette[1]
    if (load < 75) return loadPalette[2]
    return loadPalette[3]
  }

  // Feature badges are glyphs, not words, so they fit a fixed column and stop
  // shoving country names around. All four are Material Design icons from the
  // Nerd Font Omarchy ships (ttf-jetbrains-mono-nerd-basic) - checked against
  // that font's cmap, because the plain-Unicode symbols that read best here
  // (U+21C4 and U+26C9) are absent from it and would render as tofu.
  function badgeGlyph(token) {
    if (token === "p2p") return "󰓡"
    if (token === "tor") return "󰗹"
    if (token === "sc") return "󰦝"
    if (token === "plus") return "󰌾"
    return ""
  }

  function badgeTooltip(token) {
    if (token === "p2p") return "Allows peer-to-peer traffic"
    if (token === "tor") return "Routes through the Tor network"
    if (token === "sc") return "Secure Core: enters through a second country"
    if (token === "plus") return "Needs a Proton VPN Plus plan"
    return ""
  }

  // Why the list has a ListModel next to the JS array it already builds.
  //
  // Handing a ListView a NEW JS array is a full model reset, not an edit: the
  // view throws away its scroll position and snaps to the top. Measured
  // directly with a standalone ListView (contentY 500, 20 rows inserted in
  // the middle):
  //
  //   model = new JS array   ->  contentY 500 becomes 0     (reset)
  //   ListModel.insert()     ->  contentY 500 stays 500     (edit)
  //   delegate height change ->  contentY 500 stays 500     (edit)
  //
  // Since every expand/collapse rebuilds the array, the list snapped to the
  // top every time you opened a country. Restoring contentY afterwards cannot
  // fix it — by then the position is already discarded, and the restore races
  // a re-layout that has not produced a contentHeight to clamp against yet.
  // That was the first attempt at this bug, and it did not work.
  //
  // So the ListView is driven by a ListModel that holds nothing but a stable
  // `key` per row, kept in step with the array by inserting and removing only
  // what actually changed. The view therefore sees edits and keeps its
  // position. The rich row data still comes from the JS array, looked up by
  // index in the delegate — the ListModel exists purely to give the view
  // correct item lifecycle, not to store anything.
  function syncRows() {
    var desired = locationRows
    var i = 0
    while (i < desired.length) {
      if (i >= rowModel.count) { rowModel.append({ key: desired[i].key }); i++; continue }
      if (rowModel.get(i).key === desired[i].key) { i++; continue }
      // The model's row still exists further down the desired list, so what
      // is at `i` is new: insert rather than overwrite.
      var later = -1
      var currentKey = rowModel.get(i).key
      for (var j = i; j < desired.length; j++) {
        if (desired[j].key === currentKey) { later = j; break }
      }
      if (later > i) { rowModel.insert(i, { key: desired[i].key }); i++; continue }
      rowModel.remove(i, 1)
    }
    if (rowModel.count > desired.length) rowModel.remove(desired.length, rowModel.count - desired.length)
  }

  // Keeps the keyboard-selected row visible as the cursor moves. A ListView
  // owns its own scroll position and can position by index, which replaced
  // the hand-rolled contentY arithmetic this used to need when the list was
  // a Flickable wrapping a Column of every row at once. Deferred because an
  // expand changes the model and the new rows have no geometry until the
  // view has laid them out.
  function scrollCursorIntoView() {
    if (focusSection !== "locations") return
    var index = locationIndex
    Qt.callLater(function() {
      if (!locationsList || index < 0 || index >= locationsList.count) return
      locationsList.positionViewAtIndex(index, ListView.Contain)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (locationsList) locationsList.positionViewAtBeginning()
    disarmPointer()
    vpn.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }


  Service {
    id: vpn
    settings: root.settings
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: keyCatcher
  }

  // The service drops its per-country detail whenever the data it was cut
  // from changes (a server pin, or a stats reload). expandRow() only fetches
  // on a change of expanded country, so without this an already-open country
  // would sit on "Loading servers…" until collapsed and reopened.
  Connections {
    target: vpn
    function onDetailCleared() {
      if (root.expandedCountryCode !== "") vpn.loadCountryDetail(root.expandedCountryCode)
    }
  }

  // Holds one `key` per visible row and nothing else — see syncRows().
  ListModel { id: rowModel }

  // The count and percentage columns are sized to the widest value they can
  // actually hold, measured in the real font, instead of a hardcoded pixel
  // guess. The guess was both wrong (far wider than any value needs) and
  // fragile - it took no account of the theme's font scale.
  TextMetrics {
    id: countMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "5.9k"
  }

  TextMetrics {
    id: loadMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "100%"
  }

  // The array is rebuilt by a binding; this turns each rebuild into the
  // minimal set of inserts and removes on the model the view actually reads.
  onLocationRowsChanged: syncRows()
  Component.onCompleted: syncRows()

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); return "ok" }
    function connect(): string { vpn.connect(); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function toggleConnection(): string { vpn.toggleConnection(); return "ok" }
    function status(): string { return vpn.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        // The icon carries its own on/connecting/off/needs-sign-in tones (see
        // Icon.qml), so it gets the undimmed bar foreground and does the
        // dimming itself — dimming the colour here as well would stack two
        // fades.
        Icon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barForeground
          active: vpn.active
          needsLogin: vpn.needsLogin
          connecting: vpn.connecting
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleConnection()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    // Only the LOCATIONS country/city list can grow arbitrarily tall (148
    // countries, up to ~22 cities each) — it gets its own bounded, internally
    // -scrolling ListView below (id: locationsList). Everything else in
    // this column (header, connection info, account row) stays a fixed,
    // non-scrolling layout, so the popup as a whole never scrolls as one unit
    // the way an early version (mirroring the Tailscale panel's whole-column
    // Flickable) did — that made the entire popup scroll when only the
    // country list needed to.
    //
    // Deliberately NO height cap argument here: this is the network/bluetooth
    // panel's shape (fixed chrome + one internally-scrolling list), and those
    // pass no cap either — the available screen height is the only bound.
    // Passing one was the bug. A cap only truncates: the column below is a
    // positioner inside a `clip: true` Item, so it has no way to scroll to
    // whatever the cap cuts off, and the ACCOUNT row is last in the column
    // and so the first thing lost. Connecting adds the 5-row CONNECTION grid
    // and opening the picker adds the search field plus the list, which
    // together crossed the old 560 — user report: sign in/sign out became
    // unreachable with the location picker open. The cap was borrowed from
    // the Tailscale panel, where it is safe precisely because that panel
    // wraps its whole column in a Flickable and can scroll to the remainder.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") vpn.toggleConnection()
        else if (t === "p" || t === "P") root.togglePinAtCursor()
      }

      // Last-resort guard only. With no outer cap above, the popup grows to
      // fit its content and this should never have anything to clip; it stays
      // so that content exceeding even the available screen height is cut
      // cleanly at the popup's edge instead of visibly spilling out past its
      // background/border. Note what it is NOT: clipping is not what keeps
      // the content in bounds. Relying on it for that is what silently ate
      // the ACCOUNT row — a clipped positioner has no scroll to recover the
      // remainder, so anything past the edge is simply unreachable.
      Item {
        anchors.fill: parent
        clip: true

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        width: parent.width
        spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: "ProtonVPN"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Icon {
                  iconSize: Style.font.display
                  color: root.foreground
                  active: vpn.active
                  needsLogin: vpn.needsLogin
                  connecting: vpn.connecting
                }
              }

              // The service already flips `active` optimistically, so the
              // knob throws the instant you click it — same as Tailscale.
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: vpn.installed
                  enabled: !vpn.needsLogin
                  checked: vpn.active
                  busy: vpn.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: vpn.toggleConnection()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: vpn.actionStatus !== "" || vpn.lastError !== ""
            width: parent.width
            text: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
            color: vpn.lastError !== "" && vpn.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: !vpn.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "ProtonVPN CLI is not installed or not on PATH."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: vpn.installed && vpn.active
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed && vpn.active
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "CONNECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            GridLayout {
              width: parent.width
              columns: 2
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              Text {
                text: "Server"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: vpn.serverText !== "" ? vpn.serverName(vpn.serverText) : "--"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
              }

              Text {
                text: "Load"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: vpn.loadText !== "" ? vpn.loadText : "--"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
              }

              Text {
                text: "Protocol"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: vpn.protocolText !== "" ? vpn.protocolText : "--"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
              }

              // Feature 2: the tunnel interface's local IP (read straight off
              // `proton0`/`tun0`, whichever exists) and a cached public IP.
              Text {
                text: "Tunnel IP"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: vpn.tunnelIp !== "" ? vpn.tunnelIp : "--"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
              }

              Text {
                text: "Public IP"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: vpn.publicIp !== "" ? vpn.publicIp : (vpn.publicIpFailed ? "Unavailable" : "Looking up…")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            CursorSurface {
              id: locationsToggle
              width: parent.width
              hasCursor: root.locationsToggleHasCursor
              foreground: root.foreground
              implicitHeight: locationsToggleInner.implicitHeight + Style.spacing.rowPaddingX

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.setLocationsToggleCursor()
                onClicked: root.toggleLocationPicker()
              }

              RowLayout {
                id: locationsToggleInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                // Mixed pixelSizes and weights in this row (the icon and
                // chevron at Style.font.body, LOCATIONS bold vs the summary
                // regular, both at Style.font.caption) can each report a
                // slightly different implicitHeight/ascent, so AlignVCenter
                // — which centers each item's own bounding box within the
                // row — does not reliably line up their glyph baselines.
                // AlignBaseline asks the layout to align by actual text
                // baseline instead, which is what "these look aligned" means
                // for text of differing size/weight sitting side by side.
                Text {
                  text: "󰍎"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignBaseline
                }

                // Styled as the section header it replaces (PanelSectionHeader
                // is bold caption at Qt.darker(fg, 1.4)) but WITHOUT its
                // topPadding: that padding exists to keep a header's nerd-font
                // overshoot from being clipped when it sits at the top of a
                // clipping list (PanelSectionHeader's own comment) — this row
                // isn't one of those (it's inline next to sibling Text items
                // in a plain RowLayout).
                Text {
                  text: "LOCATIONS"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.alignment: Qt.AlignBaseline
                }

                // What is behind the section, so the header earns its row:
                // how much there is to pick from, without opening it.
                Text {
                  Layout.fillWidth: true
                  text: root.locationsSummary
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.alignment: Qt.AlignBaseline
                }

                Text {
                  text: root.locationPickerOpen ? "▾" : "▸"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignBaseline
                }
              }
            }

            Column {
              visible: root.locationPickerOpen
              width: parent.width
              spacing: Style.space(6)

              // Two views over the same list machinery rather than a second
              // list: ButtonGroup is the shell's own "pick one of N" control
              // and documents the panel-cursor pattern these popups use.
              ButtonGroup {
                id: locationTabs
                width: parent.width
                options: [
                  { value: "all", label: "All" },
                  { value: "recent", label: "Recent" }
                ]
                value: root.locationTab
                foreground: root.foreground
                accent: root.foreground
                fontFamily: root.fontFamily
                focusable: false
                onChanged: function(value) { root.selectTab(String(value)) }
              }

              TextField {
                id: locationSearch
                visible: root.locationTab === "all"
                width: parent.width
                foreground: root.foreground
                placeholderText: "Search countries"
                text: root.locationQuery
                onTextChanged: {
                  root.locationQuery = text
                  root.locationIndex = 0
                  root.disarmPointer()
                }
                onAccepted: root.activateSelectedLocation()
                Keys.onPressed: function(event) {
                  // Arrow keys only here, deliberately - this field is live
                  // text input, so "j"/"k" must reach the field normally
                  // (typing "Japan", "Jordan", "Kenya", etc. would otherwise
                  // be swallowed as list navigation instead of inserted).
                  if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                    root.cursorActive = true
                    root.focusSection = "locations"
                    var step = event.key === Qt.Key_Down ? 1 : -1
                    var next = root.nextSelectable(root.locationIndex, step)
                    if (next >= 0) root.locationIndex = next
                    root.ensureCursor()
                    root.disarmPointer()
                    root.scrollCursorIntoView()
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.activateSelectedLocation()
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Escape) {
                    // Via the toggle, not by setting the flag: closing has to
                    // clear the expansion state too, or reopening restores a
                    // tree the user just dismissed.
                    if (root.locationPickerOpen) root.toggleLocationPicker()
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Text {
                // Only when there is genuinely nothing to show. A background
                // refresh behind a cached list must not blank it with a
                // spinner - that was the whole point of caching it.
                visible: root.locationTab === "all" && vpn.countriesLoading && vpn.countries.length === 0
                         && !vpn.needsLogin && !vpn.countriesAuthRequired
                width: parent.width
                text: "Loading countries…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                // `protonvpn countries list` requires an active sign-in — show
                // that plainly instead of leaving this section blank when
                // signed out (root cause: exits non-zero with "Authentication
                // required..." rather than returning an empty list).
                visible: root.locationTab === "all" && (vpn.needsLogin || vpn.countriesAuthRequired)
                width: parent.width
                text: "Sign in to browse countries"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                // Only appears when the loads are genuinely old — see
                // loadAgeNotice(). Empty text the rest of the time, which is
                // almost always.
                visible: vpn.statsAvailable && vpn.loadsAgeNotice !== ""
                width: parent.width
                text: vpn.loadsAgeNotice
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                visible: root.locationTab === "all" && !vpn.needsLogin && !vpn.countriesAuthRequired && vpn.countriesLoaded && root.locationRows.length === 0
                width: parent.width
                text: "No countries found."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              // The list itself is the only part of this panel that scrolls —
              // bounded to a fixed height so the popup around it (header,
              // connection info, account row) stays put instead of the whole
              // panel scrolling as one unit. Same idiom, and the same kind of
              // fixed bound, as the network panel's ~240 and the bluetooth
              // panel's ~400 device lists.
              //
              // This bound plus the fixed rows around it is what keeps the
              // popup inside the screen now that there is no outer cap, so it
              // is a real budget rather than a cosmetic one: the fixed parts
              // come to roughly 340px when connected, leaving this list the
              // limiting factor on how tall the popup gets.
              //
              // A ListView, not a Repeater in a Column, because the model is
              // no longer 148 country rows: expanding the United States adds
              // 22 cities, and expanding one of those adds its servers. A
              // Repeater instantiates every delegate it is given; a ListView
              // only builds the handful actually on screen. Same reason the
              // bluetooth panel's device list is one.
              ListView {
                id: locationsList
                // buildLocationRows() already returns nothing while signed
                // out on this tab, so an empty model is the whole condition.
                visible: rowModel.count > 0
                width: parent.width
                height: Math.min(contentHeight, Style.space(280))
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                spacing: Style.space(4)
                model: rowModel
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: LocationRow {
                  required property int index
                  width: locationsList.width
                  // The model carries only the row's identity; the data comes
                  // from the array by index. Guarded because a delegate can
                  // outlive its row for one frame during a sync.
                  row: index >= 0 && index < root.locationRows.length ? root.locationRows[index] : null
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACCOUNT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              id: authRow
              width: parent.width
              hasCursor: root.authHasCursor
              foreground: root.foreground
              implicitHeight: authInner.implicitHeight + Style.spacing.rowPaddingX

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: vpn.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !vpn.busy
                onEntered: root.setAuthCursor()
                onClicked: root.activateAuth()
              }

              RowLayout {
                id: authInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: vpn.needsLogin ? "󰍂" : "󰍃"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    text: root.authLabel
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: root.authDetail
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }
      }
      }
    }

  // One row of the flattened location model. Country, city and server rows
  // share a delegate rather than getting three of their own: they are the
  // same shape — indent, glyph, name, feature badges, a secondary line, a
  // load meter — and a ListView delegate is instantiated and destroyed as it
  // scrolls, so one component that adapts costs less than three that a
  // DelegateChooser has to pick between.
  component LocationRow: CursorSurface {
    id: locationRow
    property var row: null
    property int rowIndex: 0

    readonly property string kind: row ? String(row.kind || "") : ""
    readonly property bool isCountry: kind === "country"
    readonly property bool isCity: kind === "city"
    readonly property bool isServer: kind === "server"
    readonly property bool isStatus: kind === "status"
    readonly property bool isRecent: kind === "recent"
    readonly property string entryKind: row ? String(row.entryKind || "") : ""
    readonly property bool canPin: root.canPin(row)
    readonly property var stats: row ? row.stats : null
    readonly property bool expanded: row ? row.expanded === true : false
    readonly property bool expandable: isCountry || isCity
    // Servers above the account's own tier are shown rather than hidden - the
    // point of the list is to show what is there - but they are dimmed and
    // carry a PLUS badge, and clicking one would only fail at the CLI.
    readonly property bool locked: isServer && row && row.locked === true
    // -1 means "no figure", which hides the meter. Guarded against NaN,
    // because a QML int property coerces NaN to 0 and a missing load would
    // otherwise render as a confident green 0%.
    readonly property int load: {
      var value = NaN
      if (isServer && row && row.server) value = Number(row.server.load)
      else if (stats && stats.load !== undefined) value = Number(stats.load)
      return isFinite(value) ? value : -1
    }

    hasCursor: root.cursorActive && root.focusSection === "locations" && root.locationIndex === rowIndex
    foreground: root.foreground
    enabled: !isStatus
    implicitHeight: !row
      ? 0
      : (isStatus
         // Was labelGap * 2, which is 8px around a line of wrapped caption
         // text - too tight, and the reason the empty-Recent message looked
         // cramped. Status rows now get the same padding as every other row.
         ? statusLabel.implicitHeight + Style.spacing.rowPaddingX
         : rowBody.implicitHeight + Style.spacing.rowPaddingX)

    // Status rows (loading, empty, "showing 20 of 875") are captions, not
    // targets: no cursor surface, no click, and the keyboard skips them.
    Text {
      id: statusLabel
      visible: locationRow.row !== null && locationRow.isStatus
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10) + (locationRow.row ? Number(locationRow.row.depth) * Style.space(14) : 0)
      anchors.rightMargin: Style.space(10)
      text: locationRow.row ? String(locationRow.row.text || "") : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    MouseArea {
      anchors.fill: parent
      enabled: !locationRow.isStatus
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: function(mouse) { root.setLocationCursorFromPointer(locationRow.rowIndex, locationRow, mouse) }
      onClicked: root.activateRow(locationRow.row)
    }

    Column {
      id: rowBody
      // Requires real data, not merely "not a status row" - with no row at
      // all the old test passed and drew an empty body over the top of
      // whatever else was visible.
      visible: locationRow.row !== null && !locationRow.isStatus
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10) + (locationRow.row ? Number(locationRow.row.depth) * Style.space(14) : 0)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      // Fixed-width slots for everything after the label, so the badge
      // column, country code and chevron line up down the whole list instead
      // of drifting with the length of each name.
      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          // Flag for a country (see countryFlagEmoji), and plain glyphs
          // deeper in - a city or a single server has no flag of its own,
          // and repeating the country's would only add noise.
          // Fixed slot whether or not there is a glyph to put in it, so an
          // absent flag (Kosovo has no flag in Unicode at all) leaves the
          // labels aligned with every other row rather than shifting left.
          Layout.preferredWidth: Style.space(16)
          // Every branch identifies its row kind POSITIVELY, and anything
          // unrecognised draws nothing. This used to end in a catch-all
          // `return "󰒋"`, which meant a status row - and any delegate whose
          // `row` had not caught up with the model for a frame - silently
          // rendered a server icon it had no business having.
          text: {
            if (!locationRow.row) return ""
            if (locationRow.isCountry) return vpn.countryFlagEmoji(String(locationRow.row.code || ""))
            if (locationRow.isCity) return "󰆑"
            if (locationRow.isServer) return "󰒋"
            // A recent row borrows the glyph of whatever it points at, so the
            // list reads as "a country / a city / a server" at a glance.
            if (locationRow.isRecent) {
              if (locationRow.entryKind === "country") return vpn.countryFlagEmoji(String(locationRow.row.code || ""))
              if (locationRow.entryKind === "city") return "󰆑"
              if (locationRow.entryKind === "server") return "󰒋"
            }
            return ""
          }
          color: locationRow.isCountry ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: locationRow.isCountry ? Style.font.body : Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          Layout.fillWidth: true
          text: locationRow.row ? String(locationRow.row.label || "") : ""
          color: locationRow.locked ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: locationRow.isServer ? Style.font.bodySmall : Style.font.body
          elide: Text.ElideRight
        }

        Text {
          visible: locationRow.viaText !== ""
          text: locationRow.viaText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        // A server is a leaf: it has no subtitle to pair a load figure with,
        // so its meter goes here and the row stays one line tall.
        LoadMeter {
          visible: locationRow.isServer && locationRow.load >= 0
          load: locationRow.load
          Layout.alignment: Qt.AlignVCenter
        }

        Item {
          Layout.preferredWidth: Style.space(38)
          Layout.alignment: Qt.AlignVCenter
          implicitHeight: badgeRow.implicitHeight

          Row {
            id: badgeRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: locationRow.row ? (locationRow.row.badges || []) : []

              Text {
                required property var modelData
                text: root.badgeGlyph(String(modelData))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body

                // Hover-only: buttons stay NoButton so a click on a badge
                // still reaches the row underneath and connects.
                MouseArea {
                  id: badgeHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: badgeHover.containsMouse
                  text: root.badgeTooltip(String(parent.modelData))
                  fontFamily: root.fontFamily
                }
              }
            }
          }
        }

        Text {
          // Reserved on every row, not just countries, so the chevron after
          // it sits at the same x all the way down.
          Layout.preferredWidth: Style.space(18)
          text: locationRow.isCountry && locationRow.row ? String(locationRow.row.code || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          Layout.alignment: Qt.AlignVCenter
        }

        PanelActionButton {
          // Pin. Solid when pinned, and otherwise only drawn while the row is
          // under the cursor - an outline pin on all 148 rows at once is
          // noise, but a slot reserved on every row keeps the columns from
          // shifting as the cursor moves.
          visible: true
          enabled: locationRow.canPin
          opacity: locationRow.row && locationRow.row.pinned === true ? 1 : (locationRow.hasCursor && locationRow.canPin ? 0.55 : 0)
          iconText: locationRow.row && locationRow.row.pinned === true ? "󰐃" : "󰤰"
          tooltipText: locationRow.row && locationRow.row.pinned === true ? "Unpin" : "Pin to the top"
          foreground: root.foreground
          fontFamily: root.fontFamily
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.togglePin(locationRow.row)
        }

        PanelActionButton {
          // Stays visible (so it keeps its slot in the layout and the column
          // lines up down the list) but goes transparent and inert on a
          // server row, which has nothing to expand. `visible: false` would
          // drop it out of the RowLayout entirely and let the columns drift.
          visible: true
          enabled: locationRow.expandable
          opacity: locationRow.expandable ? 1 : 0
          iconText: locationRow.expanded ? "▾" : "▸"
          tooltipText: locationRow.isCountry ? "Cities and servers" : "Servers"
          foreground: root.foreground
          fontFamily: root.fontFamily
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.toggleExpanded(locationRow.row)
        }
      }

      // Second line: how many servers are behind this row, where they are,
      // and how loaded the best of them is. Countries and cities only - see
      // the note on the server meter above.
      RowLayout {
        width: parent.width
        spacing: Style.space(6)
        visible: !locationRow.isServer && (locationRow.count >= 0 || locationRow.detailText !== "" || locationRow.load >= 0)

        Text {
          // The word "servers" said nothing the icon does not.
          visible: locationRow.count >= 0
          Layout.preferredWidth: Style.space(16)
          text: "󰒋"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignLeft
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          // Fixed width and right-aligned: the count runs from 4 to 6k, and
          // without this every extra digit shoved the city name sideways.
          visible: locationRow.count >= 0
          Layout.preferredWidth: countMetrics.width
          text: locationRow.count >= 0 ? vpn.formatServerCount(locationRow.count) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          Layout.fillWidth: true
          text: locationRow.detailText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        LoadMeter {
          visible: locationRow.load >= 0
          load: locationRow.load
          Layout.alignment: Qt.AlignVCenter
        }
      }
    }

    readonly property string viaText: (row && String(row.via || "") !== "") ? ("via " + String(row.via)) : ""
    readonly property int count: row && row.count !== undefined ? Number(row.count) : -1

    readonly property string detailText: {
      if (!row) return ""
      return String(row.detail || "")
    }
  }

  // Load as a bar plus a number. Proton reports it per server as a
  // percentage; low is good, so the bar reads as "how much of this server is
  // already spoken for". The colour comes from loadTone() - four bands
  // blending the theme's foreground toward its urgent colour - so it stays
  // legible on any theme instead of imposing a fixed green/amber/red ramp.
  component LoadMeter: RowLayout {
    id: meter
    property int load: -1
    readonly property color tone: root.loadTone(load)
    spacing: Style.space(6)

    Rectangle {
      width: Style.space(26)
      height: Math.max(2, Style.space(3))
      radius: height / 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
      Layout.alignment: Qt.AlignVCenter

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // A server at 0% still gets a visible sliver, so the bar never reads
        // as "no data" when it means "completely idle".
        width: Math.max(meter.load >= 0 ? parent.height : 0,
                        parent.width * Math.max(0, Math.min(100, meter.load)) / 100)
        height: parent.height
        radius: parent.radius
        color: meter.tone
      }
    }

    Text {
      // Fixed width and right-aligned for the same reason as the server
      // count: "4%" and "100%" must not move anything around them.
      Layout.preferredWidth: loadMetrics.width
      horizontalAlignment: Text.AlignRight
      text: meter.load >= 0 ? (meter.load + "%") : ""
      color: meter.tone
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      Layout.alignment: Qt.AlignVCenter
    }
  }
}
