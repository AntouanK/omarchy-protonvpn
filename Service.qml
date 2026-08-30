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
  property var citiesByCountry: ({})
  property string citiesLoadingCode: ""

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

  property string _statusOutput: ""
  property string _statusError: ""
  property string _infoOutput: ""
  property string _infoError: ""
  property string _countriesOutput: ""
  property string _countriesError: ""
  property string _citiesOutput: ""
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

  function loadCountries() {
    if (countriesLoaded || countriesLoading) return
    countriesLoading = true
    _countriesOutput = ""
    _countriesError = ""
    countriesProcess.command = ["protonvpn", "countries", "list"]
    countriesProcess.running = true
  }

  // Self-correct once the user signs back in: countriesLoaded was
  // deliberately never set true on the authRequired failure path above, so
  // the next LOCATIONS expand would retry on its own regardless — but do it
  // proactively too, the moment `info` reports we're signed in again,
  // instead of waiting for the user to re-open the picker.
  onNeedsLoginChanged: {
    if (!needsLogin && countriesAuthRequired) {
      countriesAuthRequired = false
      loadCountries()
    }
  }

  function loadCities(code) {
    var key = String(code || "")
    if (key === "" || citiesByCountry[key] !== undefined || citiesLoadingCode === key || citiesProcess.running) return
    citiesLoadingCode = key
    _citiesOutput = ""
    citiesProcess.command = ["protonvpn", "cities", "list", key]
    citiesProcess.running = true
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
    // Bounded and best-effort — a slow/unreliable network call here should
    // never hold up the rest of the panel.
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
        root.countriesAuthRequired = false
        root.countries = Model.parseCountries(stdout)
        root.countriesLoaded = true
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

  Process {
    id: citiesProcess
    running: false
    command: []
    stdout: StdioCollector { id: citiesStdout; waitForEnd: true; onStreamFinished: root._citiesOutput = text }
    stderr: StdioCollector { id: citiesStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var key = root.citiesLoadingCode
      root.citiesLoadingCode = ""
      if (exitCode === 0 && key !== "") {
        var next = {}
        for (var k in root.citiesByCountry) next[k] = root.citiesByCountry[k]
        next[key] = Model.parseCities(String(citiesStdout.text || root._citiesOutput || ""))
        root.citiesByCountry = next
      } else if (key !== "") {
        // Leave citiesByCountry[key] undefined (rather than []) so the next
        // expand attempt retries instead of being permanently treated as
        // "loaded, zero cities" - but say SOMETHING, rather than the
        // expansion silently showing neither a spinner nor an error.
        root.actionStatus = "Could not load cities"
        actionStatusTimer.restart()
      }
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
      if (exitCode === 0) root.publicIp = Model.parsePublicIp(String(publicIpStdout.text || root._publicIpOutput || ""))
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
        root.lastError = Model.elideStatus(stderr || stdout || "protonvpn connect failed")
        root.actionStatus = root.lastError
        actionStatusTimer.restart()
      } else {
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
