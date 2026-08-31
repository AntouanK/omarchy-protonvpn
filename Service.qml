import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property bool installed: false
  property bool needsLogin: false
  property bool running: false

  // Optimistic state so the icon/switch react the instant you click, rather
  // than waiting for the next status poll to confirm it. -1 means "just
  // follow the real state"; 0/1 means a toggle is still catching up.
  // Mirrors the Tailscale service's `_desired`.
  property int _desired: -1
  readonly property bool active: _desired === -1 ? running : (_desired === 1)
  // The in-between window: a connect has been asked for and `active` is
  // already reporting true optimistically, but `protonvpn status` has not yet
  // come back saying the tunnel is really up. `parseStatus()` clears
  // `_desired` the moment reality catches up, so this goes false on its own
  // — nothing else has to reset it. The icon uses it to show the link as
  // still being built rather than as established.
  readonly property bool connecting: _desired === 1 && !running

  property bool refreshing: false
  property string statusText: "Checking…"
  property string accountName: ""
  property string serverText: ""
  property string loadText: ""
  property string protocolText: ""
  property string actionStatus: ""
  property string lastError: ""

  // Connection detail extras (Feature 2): the tunnel interface's local IP and
  // a cached public IP, both refreshed once when a connection is (re-)established.
  property string tunnelIp: ""
  property string publicIp: ""
  // So the panel can stop saying "Looking up…" once the lookup is actually
  // over. A silent permanent "Looking up…" is worse than saying it failed.
  property bool publicIpFailed: false
  property bool _publicIpTriedV4: false

  // Country/city picker (Feature 1): loaded lazily and cached for the life of
  // the panel — 150 countries is not something worth re-fetching every poll.
  property var countries: []
  property bool countriesLoaded: false
  property bool countriesLoading: false
  // `protonvpn countries list` refuses to serve the full list while signed
  // out — confirmed directly on this machine (signed-out account): it exits
  // 2 (not 0) and prints "Error: Authentication required to view complete
  // country list. Please sign in with 'protonvpn signin'" to stderr, with a
  // "Server list is outdated, updating..." notice on stdout beforehand.
  // Tracked separately from the generic needsLogin (which comes from a
  // different call, `protonvpn info`) so the LOCATIONS section can show a
  // precise reason instead of silently rendering an empty list.
  property bool countriesAuthRequired: false

  // Server intelligence: server counts, per-city breakdowns and live load
  // figures, read out of the CLI daemon's own on-disk cache with jq. See the
  // long note above SERVER_STATS_QUERY in Model.js for why this is the only
  // available source — the CLI reports none of it and Proton's API is closed.
  //
  // XDG_CACHE_HOME with a ~/.cache fallback, same as the agents plugin does
  // for XDG_STATE_HOME. Resolved once here rather than shelling out, so the
  // jq processes below need no shell and therefore no quoting.
  readonly property string _cacheHome: (Quickshell.env("XDG_CACHE_HOME") || "") !== ""
    ? Quickshell.env("XDG_CACHE_HOME")
    : ((Quickshell.env("HOME") || "") + "/.cache")
  readonly property string serverCachePath: _cacheHome + "/Proton/VPN/serverlist.json"

  // Recents and pins, persisted where the other Omarchy plugins keep their
  // state (the clipboard plugin's history lives beside this).
  readonly property string _stateHome: (Quickshell.env("XDG_STATE_HOME") || "") !== ""
    ? Quickshell.env("XDG_STATE_HOME")
    : ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string statePath: _stateHome + "/omarchy/protonvpn-state.json"

  property var recentConnections: []
  property var pinnedCountries: []
  property var pinnedServers: []
  readonly property int recentLimit: 20
  // Set once the file has been read (or failed to read), so a save triggered
  // before the first load cannot write an empty list over real state.
  property bool stateLoaded: false
  // What a connect in flight would add to the recents if it succeeds. Held
  // rather than recorded up front: a connection that fails is not somewhere
  // you have been, and would otherwise sit at the top of the list.
  property var _pendingRecent: null

  property var countryStats: ({})
  property bool statsLoading: false
  // Distinct from "loaded": the cache is absent on a fresh install and until
  // the daemon has run once while signed in. False means the picker shows
  // plain country names, exactly as it did before this feature, rather than
  // showing an error for something the user cannot act on.
  property bool statsAvailable: false
  property int accountTier: 0
  // Roughly how old the cached load figures are, in minutes (-1 when unknown).
  // Not a boolean: see the note above the query in Model.js — the expiry the
  // cache carries is the daemon's refresh schedule, so "past expiry" is
  // normal and says nothing. Only a genuinely large age is worth a word, and
  // loadAgeNotice() decides where that line is.
  property int loadsAgeMinutes: -1
  readonly property string loadsAgeNotice: Model.loadAgeNotice(loadsAgeMinutes)
  property double _statsLoadedAtMs: 0
  property double countriesCachedAtMs: 0
  // Countries change on the order of never, so a cached list is good for a
  // long time. It is still refreshed in the background past this, with the
  // cached one on screen throughout.
  readonly property int countriesMaxAgeMs: 21600000
  // Loads are the perishable part of this data, so unlike the country list
  // (fetched once for the life of the panel) the roll-up is re-read when the
  // picker is opened again after a few minutes.
  readonly property int statsMaxAgeMs: 300000

  property var detailByCountry: ({})
  property string detailLoadingCode: ""
  // A second expand issued while the first is still running would otherwise
  // be dropped by the running-process guard, leaving a country stuck on
  // "Loading…" until it was collapsed and reopened.
  property string _detailPendingCode: ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property bool busy: whichProcess.running || infoProcess.running || statusProcess.running || connectProcess.running || disconnectProcess.running

  // --- Flicker fix -----------------------------------------------------
  // `protonvpn status` calls out to Proton's API for the live server list
  // whenever a connection is active (to report Load%), and `info` can hit
  // the API too — so a poll failure here is often just a transient network
  // blip, not proof the tunnel dropped or the account signed out. The
  // watchdog below can also kill a poll that simply took too long, which
  // looks identical to a real failure from the process's exit code alone.
  // Tracking a short streak means one bad poll no longer flips the icon —
  // it takes a few in a row (or the CLI explicitly saying "not logged in")
  // before we believe it and update `running`/`needsLogin`.
  property int _statusFailStreak: 0
  property int _infoFailStreak: 0
  readonly property int maxPollFailStreak: 3

  property string _statsOutput: ""
  property string _detailOutput: ""
  property string _statusOutput: ""
  property string _statusError: ""
  property string _infoOutput: ""
  property string _infoError: ""
  property string _countriesOutput: ""
  property string _countriesError: ""
  property string _tunnelIpOutput: ""
  property string _publicIpOutput: ""
  property string _actionOutput: ""
  property string _actionError: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function elideStatus(text) {
    return Model.elideStatus(text)
  }

  function serverLocation(server) {
    return Model.serverLocation(server)
  }

  function serverName(server) {
    return Model.serverName(server)
  }

  function countryFlagEmoji(code) {
    return Model.countryFlagEmoji(code)
  }

  // Same thin re-export as the three above, so the panel keeps talking to one
  // object instead of importing Model.js itself.
  function describeCountry(stats) {
    return Model.describeCountry(stats)
  }

  function formatServerCount(count) {
    return Model.formatServerCount(count)
  }

  function featureBadges(entry) {
    return Model.featureBadges(entry)
  }

  function isLocked(tier) {
    return Model.isLocked(tier, accountTier)
  }

  function resetUnavailable(message) {
    // Deliberately does NOT touch needsLogin/accountName - this is called
    // when `protonvpn status` (connection state) can't be read, which says
    // nothing about whether the account is signed in (that's infoProcess's
    // own, separately-tracked domain). Touching it here used to let a run of
    // status failures on a genuinely signed-out account briefly force
    // needsLogin back to false, showing "Sign out" as if signed in.
    running = false
    _desired = -1
    statusText = message
    serverText = ""
    loadText = ""
    protocolText = ""
    tunnelIp = ""
    publicIp = ""
  }

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) {
        refreshing = true
        whichProcess.command = ["which", "protonvpn"]
        whichProcess.running = true
      }
      return
    }
    refreshStatusAndAccount()
  }

  function refreshStatusAndAccount() {
    if (!installed) return
    var launched = false
    if (!statusProcess.running) {
      _statusOutput = ""
      _statusError = ""
      refreshing = true
      statusProcess.command = ["protonvpn", "status"]
      statusProcess.running = true
      launched = true
    }
    if (!infoProcess.running) {
      _infoOutput = ""
      _infoError = ""
      infoProcess.command = ["protonvpn", "info"]
      infoProcess.running = true
      launched = true
    }
    // Arm the watchdog on the launch that needs watching, same pattern as
    // Tailscale: a hung CLI call would otherwise silently stop the panel
    // refreshing forever.
    if (launched && !pollWatchdog.running) pollWatchdog.start()
  }

  function parseStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.message || "Failed to parse ProtonVPN status"
      console.warn("protonvpn", lastError)
      return
    }
    var wasRunning = running
    running = parsed.connected
    // Reality caught up to the pending toggle — stop overriding.
    if (_desired !== -1 && running === (_desired === 1)) _desired = -1
    serverText = parsed.server
    loadText = parsed.load
    protocolText = parsed.protocol
    statusText = running ? "Connected" : "Disconnected"
    lastError = ""

    if (running && !wasRunning) {
      // Newly (or freshly-discovered) connected — pick up the tunnel/public
      // IP for the panel. Cheap and only happens on a state transition.
      refreshTunnelIp()
      refreshPublicIp()
    } else if (!running && wasRunning) {
      tunnelIp = ""
      publicIp = ""
    }
  }

  function parseInfo(exitCode, raw) {
    // exitCode alone doesn't mean signed in — `protonvpn info` exits 0 even
    // when signed out, printing the literal placeholder `Account: 'None'`
    // (Model.parseAccountName already normalizes that placeholder to "").
    // So the real signal is whether a non-empty account name came back.
    var name = exitCode === 0 ? Model.parseAccountName(raw) : ""
    if (name !== "") {
      needsLogin = false
      accountName = name
    } else {
      needsLogin = true
      accountName = ""
      // A pending connect/disconnect can't complete without an account —
      // stop pretending it will.
      _desired = -1
    }
  }

  // `force` refetches behind a list that is already on screen; without it a
  // list we already have is kept and nothing is fetched.
  function loadCountries(force) {
    if (countriesLoading) return
    if (force !== true && countriesLoaded) return
    countriesLoading = true
    _countriesOutput = ""
    _countriesError = ""
    countriesProcess.command = ["protonvpn", "countries", "list"]
    countriesProcess.running = true
  }

  // Called when the picker opens. Whatever is cached stays on screen; a
  // refetch only happens if there is nothing at all, or the cache is old.
  function refreshCountries() {
    // Forced: an empty list can coexist with countriesLoaded === true now
    // that a cached list sets that flag, and an un-forced call would return
    // immediately and leave the picker permanently empty.
    if (!countriesLoaded || countries.length === 0) { loadCountries(true); return }
    if (Date.now() - countriesCachedAtMs > countriesMaxAgeMs) loadCountries(true)
  }

  // Self-correct once the user signs back in: countriesLoaded was
  // deliberately never set true on the authRequired failure path above, so
  // the next LOCATIONS expand would retry on its own regardless — but do it
  // proactively too, the moment `info` reports we're signed in again,
  // instead of waiting for the user to re-open the picker.
  onNeedsLoginChanged: {
    if (!needsLogin && countriesAuthRequired) {
      countriesAuthRequired = false
      loadCountries(true)
    }
  }

  function loadState(raw) {
    var parsed = Model.parseState(raw)
    recentConnections = parsed.recent
    pinnedCountries = parsed.pinnedCountries
    pinnedServers = parsed.pinnedServers
    // Adopt the cached country list only if the live one has not already
    // arrived, so a slow file read can never overwrite fresher data.
    if (parsed.countries.length > 0 && countries.length === 0) {
      countries = parsed.countries
      countriesCachedAtMs = parsed.countriesCachedAt
      // Counts as loaded: the picker shows it immediately, and the age check
      // in refreshCountries() is what decides whether to go and refresh it.
      countriesLoaded = true
    }
    stateLoaded = true
  }

  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({
      version: 1,
      recent: recentConnections.slice(0, recentLimit),
      pinnedCountries: pinnedCountries,
      pinnedServers: pinnedServers,
      countries: countries,
      countriesCachedAt: countriesCachedAtMs
    }, null, 2) + "\n")
  }

  function rememberConnection(entry) {
    if (!entry) return
    recentConnections = Model.addRecent(recentConnections, entry, recentLimit)
    saveState()
  }

  function isCountryPinned(code) {
    return Model.listContains(pinnedCountries, code)
  }

  function toggleCountryPin(code) {
    pinnedCountries = Model.toggleInList(pinnedCountries, code)
    saveState()
  }

  function isServerPinned(name) {
    return Model.listContains(pinnedServers, name)
  }

  function toggleServerPin(name) {
    pinnedServers = Model.toggleInList(pinnedServers, name)
    // The cached per-country detail was cut with the OLD pin list baked into
    // it (the query unions pinned servers in past its 20-row cap), so it no
    // longer matches. Dropping it is not enough on its own: expandRow() only
    // fetches on a CHANGE of expanded country, so a country that is already
    // open would sit on "Loading servers…" until it was collapsed and
    // reopened. detailCleared() lets the panel re-request what it is showing.
    detailByCountry = ({})
    saveState()
    detailCleared()
  }

  // Emitted whenever detailByCountry is dropped wholesale, so whoever has a
  // country expanded can ask for it again.
  signal detailCleared()

  function describeRecent(entry) {
    return Model.describeRecent(entry)
  }

  function recentKey(entry) {
    return Model.recentKey(entry)
  }

  function loadServerStats(force) {
    if (statsLoading) return
    var age = Date.now() - _statsLoadedAtMs
    if (force !== true && _statsLoadedAtMs > 0 && age < statsMaxAgeMs) return
    statsLoading = true
    _statsOutput = ""
    statsProcess.command = ["jq", "-c", Model.SERVER_STATS_QUERY, serverCachePath]
    statsProcess.running = true
  }

  function loadCountryDetail(code) {
    var key = String(code || "")
    if (key === "" || detailByCountry[key] !== undefined) return
    if (detailProcess.running) { _detailPendingCode = key; return }
    detailLoadingCode = key
    _detailOutput = ""
    detailProcess.command = ["jq", "-c", "--arg", "cc", key,
                             "--argjson", "pins", JSON.stringify(pinnedServers),
                             Model.COUNTRY_DETAIL_QUERY, serverCachePath]
    detailProcess.running = true
  }

  // Connecting to one named server (`protonvpn connect GR#5`) rather than to
  // a country or city. Same guards as connectLocation() - see the note there
  // about why the opposite direction has to be guarded too.
  function countryNameFor(code) {
    var key = String(code || "")
    for (var i = 0; i < countries.length; i++) {
      if (String(countries[i].code || "") === key) return String(countries[i].name || key)
    }
    return key
  }

  function connectServer(name, countryCode, cityName) {
    if (!installed || needsLogin || connectProcess.running || disconnectProcess.running) return
    var server = String(name || "")
    if (server === "") return
    _pendingRecent = { kind: "server", name: server,
                       code: String(countryCode || ""), city: String(cityName || "") }
    _desired = 1
    _actionOutput = ""
    _actionError = ""
    actionStatus = "Connecting to " + server + "…"
    connectProcess.command = ["protonvpn", "connect", server]
    connectProcess.running = true
  }

  function connectLocation(countryCode, cityName) {
    // Guard against the opposite direction too, not just a second connect —
    // without this, a quick double-activate of the toggle could launch
    // `protonvpn connect` and `protonvpn disconnect` at the same time,
    // racing the underlying VPN daemon.
    if (!installed || needsLogin || connectProcess.running || disconnectProcess.running) return
    var code = String(countryCode || "")
    if (code === "") return
    var city = String(cityName || "")
    _desired = 1
    _actionOutput = ""
    _actionError = ""
    actionStatus = "Connecting to " + (city !== "" ? (city + ", " + code) : code) + "…"
    _pendingRecent = city !== ""
      ? { kind: "city", code: code, city: city }
      : { kind: "country", code: code, label: countryNameFor(code) }
    var cmd = ["protonvpn", "connect", "--country", code]
    if (city !== "") { cmd.push("--city"); cmd.push(city) }
    connectProcess.command = cmd
    connectProcess.running = true
  }

  function refreshTunnelIp() {
    if (tunnelIpProcess.running) return
    _tunnelIpOutput = ""
    tunnelIpProcess.command = ["bash", "-c", "ip -4 -o addr show proton0 2>/dev/null; ip -4 -o addr show tun0 2>/dev/null"]
    tunnelIpProcess.running = true
  }

  function refreshPublicIp() {
    if (publicIpProcess.running) return
    _publicIpOutput = ""
    publicIpFailed = false
    // -4 because the row above this one shows the IPv4 tunnel address, so an
    // IPv6 answer here would be comparing two different things. Without it
    // curl returns whichever family resolves first, which on this machine is
    // IPv6 — and that answer was then dropped by the IPv4-only parser,
    // leaving the field stuck on "Looking up…" for good.
    //
    // Bounded and best-effort — a slow/unreliable network call here should
    // never hold up the rest of the panel.
    _publicIpTriedV4 = true
    publicIpProcess.command = ["curl", "-s", "-4", "--max-time", "4", "https://ifconfig.me"]
    publicIpProcess.running = true
  }

  // A v6-only host has no IPv4 answer to give, so -4 simply fails there and
  // the row would read "Unavailable" forever while the parser's IPv6 branch
  // sat unreachable. One retry without -4 makes that branch real.
  function retryPublicIpAnyFamily() {
    if (publicIpProcess.running) return
    _publicIpTriedV4 = false
    _publicIpOutput = ""
    publicIpProcess.command = ["curl", "-s", "--max-time", "4", "https://ifconfig.me"]
    publicIpProcess.running = true
  }

  function toggleConnection() {
    if (!installed || needsLogin) return
    if (active) disconnect()
    else connect()
  }

  function connect() {
    // Cross-guarded against disconnectProcess too - see connectLocation()'s
    // comment for why.
    if (!installed || needsLogin || connectProcess.running || disconnectProcess.running) return
    _desired = 1
    _actionOutput = ""
    _actionError = ""
    actionStatus = "Connecting…"
    connectProcess.command = ["protonvpn", "connect"]
    connectProcess.running = true
  }

  function disconnect() {
    // Cross-guarded against connectProcess too - see connectLocation()'s
    // comment for why.
    if (!installed || disconnectProcess.running || connectProcess.running) return
    _desired = 0
    _actionOutput = ""
    _actionError = ""
    disconnectProcess.command = ["protonvpn", "disconnect"]
    disconnectProcess.running = true
  }

  // `protonvpn signin` demands a masked password typed at a real TTY — there
  // is no non-interactive path. Quickshell's Process has no PTY, so rather
  // than hang forever we hand off to a real terminal and let the normal
  // status/info poll notice the new logged-in state once the user finishes.
  function signIn() {
    Quickshell.execDetached(["omarchy-launch-terminal", "--", "bash", "-c",
      "read -p 'Proton username: ' u && protonvpn signin \"$u\"; echo; read -p 'Press enter to close...' _"])
  }

  // Headless and safe to run directly — no prompts. Left as a real action
  // for the panel's Sign out button, but never invoked outside user intent.
  function signOut() {
    if (!installed || signoutProcess.running) return
    _actionOutput = ""
    _actionError = ""
    actionStatus = "Signing out…"
    signoutProcess.command = ["protonvpn", "signout"]
    signoutProcess.running = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Same role as Tailscale's pollWatchdog: reap a hung status/info call so
    // one bad poll doesn't silently freeze the widget forever. Deliberately
    // longer than the default refreshIntervalSec (15s) so a call that's just
    // slow — `status` hits Proton's API for the live server list whenever
    // connected — has real room to finish naturally instead of racing this
    // timer. A kill here still only counts as one soft failure (see
    // maxPollFailStreak) — it does NOT by itself flip the displayed state.
    id: pollWatchdog
    interval: 20000
    repeat: false
    onTriggered: {
      if (statusProcess.running) statusProcess.running = false
      if (infoProcess.running) infoProcess.running = false
    }
  }

  Process {
    id: whichProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refreshStatusAndAccount()
      else {
        root.refreshing = false
        root.resetUnavailable("Not installed")
      }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) {
        root._statusFailStreak = 0
        root.parseStatus(stdout)
        return
      }
      // `status` never legitimately reports an auth problem, so any failure
      // here — a network blip fetching the live server list, a watchdog kill,
      // a busy daemon — is transient. Keep showing the last known-good state
      // and let the next scheduled poll retry; only give up and show
      // "Unavailable" after several in a row.
      root._statusFailStreak++
      var combined = stderr || stdout || ""
      if (root._statusFailStreak < root.maxPollFailStreak) {
        console.warn("protonvpn", "status poll failed (" + root._statusFailStreak + "/" + root.maxPollFailStreak + "), keeping last known state:", Model.elideStatus(combined))
        return
      }
      root.resetUnavailable("Unavailable")
      root.lastError = Model.elideStatus(combined)
    }
  }

  Process {
    id: infoProcess
    running: false
    command: []
    stdout: StdioCollector { id: infoStdout; waitForEnd: true; onStreamFinished: root._infoOutput = text }
    stderr: StdioCollector { id: infoStderr; waitForEnd: true; onStreamFinished: root._infoError = text }
    onExited: function(exitCode) {
      var stdout = String(infoStdout.text || root._infoOutput || "")
      var stderr = String(infoStderr.text || root._infoError || "")
      if (exitCode === 0) {
        root._infoFailStreak = 0
        root.parseInfo(exitCode, stdout)
        return
      }
      var combined = stderr || stdout || ""
      if (Model.classifyCliFailure(combined) === "authRequired") {
        // The CLI told us, explicitly, that we're signed out — trust that
        // immediately rather than waiting out the streak.
        root._infoFailStreak = 0
        root.parseInfo(exitCode, stdout)
        return
      }
      root._infoFailStreak++
      if (root._infoFailStreak < root.maxPollFailStreak) {
        console.warn("protonvpn", "info poll failed (" + root._infoFailStreak + "/" + root.maxPollFailStreak + "), keeping last known state:", Model.elideStatus(combined))
        return
      }
      // Retries exhausted on a failure that was NOT an explicit "you're
      // signed out" from the CLI - e.g. a sustained network blip. Calling
      // parseInfo(exitCode, stdout) here would always yield an empty account
      // name (its own logic treats any non-zero exit as "no name"), forcing
      // needsLogin=true and showing "Sign in to ProtonVPN" for a still-signed
      // -in account just because the network is flaky - the same class of
      // bug the whole streak mechanism exists to prevent. Surface the
      // failure without touching needsLogin/accountName; the next successful
      // poll (or an explicit authRequired failure, handled above) is what
      // actually updates sign-in state.
      root.lastError = Model.elideStatus(combined)
    }
  }

  Process {
    id: countriesProcess
    running: false
    command: []
    stdout: StdioCollector { id: countriesStdout; waitForEnd: true; onStreamFinished: root._countriesOutput = text }
    stderr: StdioCollector { id: countriesStderr; waitForEnd: true; onStreamFinished: root._countriesError = text }
    onExited: function(exitCode) {
      root.countriesLoading = false
      var stdout = String(countriesStdout.text || root._countriesOutput || "")
      var stderr = String(countriesStderr.text || root._countriesError || "")
      if (exitCode === 0) {
        var fetched = Model.parseCountries(stdout)
        root.countriesAuthRequired = false
        // A parse that yields nothing is a bad response, not an empty world -
        // keep whatever is already on screen rather than blanking the picker.
        if (fetched.length > 0) {
          root.countries = fetched
          root.countriesLoaded = true
          root.countriesCachedAtMs = Date.now()
          root.saveState()
        }
        return
      }
      if (Model.classifyCliFailure(stderr || stdout) === "authRequired") {
        // Signed out: show a clear reason instead of a silently empty list.
        // Deliberately leave countriesLoaded false (never cache this as a
        // successful-but-empty load) so the very next LOCATIONS expand, or
        // the automatic retry once needsLogin clears (see onNeedsLoginChanged
        // below), tries again instead of being stuck showing nothing forever.
        root.countriesAuthRequired = true
        root.countries = []
        return
      }
      // Some other failure (network blip, CLI bug) — not specifically an
      // auth problem. Leave countriesLoaded false so the next picker-open
      // retries.
      root.countriesAuthRequired = false
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    // No file yet is the normal first-run case, not an error.
    onLoadFailed: root.loadState("")
    onFileChanged: reload()
  }

  Process {
    id: statsProcess
    running: false
    command: []
    stdout: StdioCollector { id: statsStdout; waitForEnd: true; onStreamFinished: root._statsOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.statsLoading = false
      // A missing cache file is the expected case on a fresh install, so jq
      // exiting non-zero is not worth surfacing as an error - it just means
      // no enrichment, and the picker falls back to plain country names.
      var parsed = exitCode === 0 ? Model.parseServerStats(String(statsStdout.text || root._statsOutput || "")) : null
      if (!parsed) {
        root.statsAvailable = false
        return
      }
      root.countryStats = parsed.byCountry
      root.accountTier = parsed.maxTier
      root.loadsAgeMinutes = parsed.loadsAgeMinutes
      root.statsAvailable = true
      root._statsLoadedAtMs = Date.now()
      // The per-country breakdowns were cut from the same file, so they carry
      // the same load figures this roll-up just replaced. Dropping them keeps
      // a country's expanded detail from disagreeing with its own summary row
      // - but see toggleServerPin(): an expanded country has to be told to
      // ask again, or it is stuck showing "Loading servers…".
      root.detailByCountry = ({})
      root.detailCleared()
    }
  }

  Process {
    id: detailProcess
    running: false
    command: []
    stdout: StdioCollector { id: detailStdout; waitForEnd: true; onStreamFinished: root._detailOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var key = root.detailLoadingCode
      root.detailLoadingCode = ""
      if (key !== "") {
        var parsed = exitCode === 0 ? Model.parseCountryDetail(String(detailStdout.text || root._detailOutput || "")) : null
        // Cache the failure as null rather than leaving the key undefined:
        // undefined means "not asked for yet" and would re-run jq over 24MB
        // on every repaint of an expanded country that has no data.
        var next = {}
        for (var k in root.detailByCountry) next[k] = root.detailByCountry[k]
        next[key] = parsed
        root.detailByCountry = next
      }
      // Whatever was asked for while this one was in flight.
      var pending = root._detailPendingCode
      root._detailPendingCode = ""
      if (pending !== "" && pending !== key) root.loadCountryDetail(pending)
    }
  }

  Process {
    id: tunnelIpProcess
    running: false
    command: []
    stdout: StdioCollector { id: tunnelIpStdout; waitForEnd: true; onStreamFinished: root._tunnelIpOutput = text }
    onExited: function(exitCode) {
      root.tunnelIp = root.running ? Model.parseTunnelIp(String(tunnelIpStdout.text || root._tunnelIpOutput || "")) : ""
    }
  }

  Process {
    id: publicIpProcess
    running: false
    command: []
    stdout: StdioCollector { id: publicIpStdout; waitForEnd: true; onStreamFinished: root._publicIpOutput = text }
    onExited: function(exitCode) {
      if (!root.running) return
      var value = exitCode === 0 ? Model.parsePublicIp(String(publicIpStdout.text || root._publicIpOutput || "")) : ""
      if (value === "" && root._publicIpTriedV4) {
        root.retryPublicIpAnyFamily()
        return
      }
      root.publicIp = value
      root.publicIpFailed = value === ""
    }
  }

  Process {
    id: connectProcess
    running: false
    command: []
    stdout: StdioCollector { id: connectStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: connectStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(connectStdout.text || root._actionOutput || "")
      var stderr = String(connectStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root._pendingRecent = null
        root.lastError = Model.elideStatus(stderr || stdout || "protonvpn connect failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.rememberConnection(root._pendingRecent)
        root._pendingRecent = null
        root.lastError = ""
        root.actionStatus = ""
        // Unconditional, not just left to parseStatus()'s own
        // running-&&-!wasRunning transition check: connectLocation() reuses
        // this same process to switch servers while ALREADY connected, and
        // that transition never fires again once running is already true -
        // which used to leave the panel showing the previous server's stale
        // tunnel/public IP after a location switch.
        root.refreshTunnelIp()
        root.refreshPublicIp()
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: disconnectProcess
    running: false
    command: []
    stdout: StdioCollector { id: disconnectStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
    stderr: StdioCollector { id: disconnectStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stdout = String(disconnectStdout.text || root._actionOutput || "")
      var stderr = String(disconnectStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = Model.elideStatus(stderr || stdout || "protonvpn disconnect failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
      }
      delayedRefresh.restart()
    }
  }

  Process {
    id: signoutProcess
    running: false
    command: []
    stdout: StdioCollector { id: signoutStdout; waitForEnd: true }
    stderr: StdioCollector { id: signoutStderr; waitForEnd: true; onStreamFinished: root._actionError = text }
    onExited: function(exitCode) {
      var stderr = String(signoutStderr.text || root._actionError || "")
      if (exitCode !== 0) {
        root.lastError = Model.elideStatus(stderr || "protonvpn signout failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
        root.lastError = ""
        root.actionStatus = ""
        root.needsLogin = true
        root.accountName = ""
      }
      delayedRefresh.restart()
    }
  }
}
