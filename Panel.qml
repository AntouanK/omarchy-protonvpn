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
  readonly property var filteredCountries: filterCountries()

  function filterCountries() {
    var query = String(locationQuery || "").trim().toLowerCase()
    if (query === "") return vpn.countries
    var result = []
    for (var i = 0; i < vpn.countries.length; i++) {
      var country = vpn.countries[i]
      var label = (String(country.name || "") + " " + String(country.code || "")).toLowerCase()
      if (label.indexOf(query) !== -1) result.push(country)
    }
    return result
  }

  function ensureCursor() {
    if (focusSection === "locations" && filteredCountries.length === 0) focusSection = "locationsToggle"
    if (focusSection === "locations") locationIndex = Math.max(0, Math.min(locationIndex, filteredCountries.length - 1))
    if (focusSection !== "header" && focusSection !== "auth" && focusSection !== "locationsToggle" && focusSection !== "locations") focusSection = "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (focusSection === "header") {
      if (dy > 0) focusSection = "locationsToggle"
    } else if (focusSection === "locationsToggle") {
      if (dy < 0) focusSection = "header"
      else if (locationPickerOpen && filteredCountries.length > 0) { focusSection = "locations"; locationIndex = 0 }
      else focusSection = "auth"
    } else if (focusSection === "locations") {
      if (dy < 0) {
        if (locationIndex <= 0) focusSection = "locationsToggle"
        else locationIndex--
      } else if (locationIndex < filteredCountries.length - 1) {
        locationIndex++
      } else {
        focusSection = "auth"
      }
    } else if (focusSection === "auth") {
      if (dy < 0) focusSection = locationPickerOpen && filteredCountries.length > 0 ? "locations" : "locationsToggle"
    }
    ensureCursor()
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

  function toggleLocationPicker() {
    locationPickerOpen = !locationPickerOpen
    if (locationPickerOpen) vpn.loadCountries()
  }

  function selectedCountry() {
    if (filteredCountries.length === 0) return null
    return filteredCountries[Math.max(0, Math.min(locationIndex, filteredCountries.length - 1))]
  }

  function activateSelectedLocation() {
    var country = selectedCountry()
    if (country) vpn.connectLocation(country.code, "")
  }

  function toggleExpandedCountry(code) {
    var key = String(code || "")
    if (expandedCountryCode === key) { expandedCountryCode = ""; return }
    expandedCountryCode = key
    vpn.loadCities(key)
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

  function setLocationCursor(index) {
    cursorActive = true
    focusSection = "locations"
    locationIndex = index
    scrollCursorIntoView()
  }

  // Keeps the keyboard-selected row visible inside the LOCATIONS list's own
  // scroll region as the cursor moves — same approach as the Tailscale
  // panel's peer/exit-node scrolling, just scoped to that one sub-list
  // instead of the whole popup (the rest of the panel no longer scrolls).
  function scrollItemIntoView(item) {
    if (!locationsFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(locationsFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = locationsFlick.contentY
      var viewBottom = viewTop + locationsFlick.height
      var maxY = Math.max(0, locationsFlick.contentHeight - locationsFlick.height)
      if (top < viewTop + margin) locationsFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) locationsFlick.contentY = Math.min(maxY, bottom + margin - locationsFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "locations" && locationColumn && locationIndex >= 0 && locationIndex < locationColumn.children.length) scrollItemIntoView(locationColumn.children[locationIndex])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (locationsFlick) locationsFlick.contentY = 0
    vpn.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onLocationIndexChanged: scrollCursorIntoView()

  Service {
    id: vpn
    settings: root.settings
  }

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
    // -scrolling Flickable below (id: locationsFlick). Everything else in
    // this column (header, connection info, account row) stays a fixed,
    // non-scrolling layout, so the popup as a whole no longer scrolls as one
    // unit the way an early version (mirroring the Tailscale panel's
    // whole-column Flickable) did — that made the entire popup scroll when
    // only the country list needed to.
    // 560 matches the cap the Tailscale panel uses for its own long-content
    // case — large enough that the fixed parts (header, connection info,
    // LOCATIONS toggle + search field, ACCOUNT row) plus the country list's
    // own bounded height (capped separately below, ~200px) always fit
    // together without needing this outer cap to actually kick in.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

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
      }

      // Clips (without scrolling) so that if the content ever exceeds the
      // outer cap above for any reason, it's cut off cleanly at the popup's
      // edge instead of visibly spilling out past the popup's background/
      // border the way it did with no clipping container at all here (the
      // bug the user hit: opening LOCATIONS pushed the ACCOUNT row out past
      // the bottom of the popup with nothing to contain it).
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
                text: vpn.publicIp !== "" ? vpn.publicIp : "Looking up…"
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

            PanelSectionHeader {
              text: "LOCATIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

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

                Text {
                  text: "󰍎"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  Layout.alignment: Qt.AlignVCenter
                }

                Text {
                  Layout.fillWidth: true
                  text: "Choose location"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: root.locationPickerOpen ? "▾" : "▸"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            Column {
              visible: root.locationPickerOpen
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: locationSearch
                width: parent.width
                foreground: root.foreground
                placeholderText: "Search countries"
                text: root.locationQuery
                onTextChanged: {
                  root.locationQuery = text
                  root.locationIndex = 0
                }
                onAccepted: root.activateSelectedLocation()
                Keys.onPressed: function(event) {
                  // Arrow keys only here, deliberately - this field is live
                  // text input, so "j"/"k" must reach the field normally
                  // (typing "Japan", "Jordan", "Kenya", etc. would otherwise
                  // be swallowed as list navigation instead of inserted).
                  if (event.key === Qt.Key_Down) {
                    root.cursorActive = true
                    root.focusSection = "locations"
                    root.locationIndex = Math.min(root.locationIndex + 1, Math.max(0, root.filteredCountries.length - 1))
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Up) {
                    root.cursorActive = true
                    root.focusSection = "locations"
                    root.locationIndex = Math.max(root.locationIndex - 1, 0)
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.activateSelectedLocation()
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Escape) {
                    root.locationPickerOpen = false
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              Text {
                visible: vpn.countriesLoading && !vpn.needsLogin && !vpn.countriesAuthRequired
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
                visible: vpn.needsLogin || vpn.countriesAuthRequired
                width: parent.width
                text: "Sign in to browse countries"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                visible: !vpn.needsLogin && !vpn.countriesAuthRequired && vpn.countriesLoaded && root.filteredCountries.length === 0
                width: parent.width
                text: "No countries found."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              // The list itself is the only part of this panel that scrolls —
              // bounded to a fixed height (~6-7 rows) so the popup around it
              // (header, connection info, account row) stays put instead of
              // the whole panel scrolling as one unit.
              Flickable {
                id: locationsFlick
                visible: root.filteredCountries.length > 0
                width: parent.width
                height: Math.min(locationColumn.implicitHeight, Style.space(200))
                contentWidth: width
                contentHeight: locationColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                Column {
                  id: locationColumn
                  width: locationsFlick.width
                  spacing: Style.space(4)

                  Repeater {
                    model: root.filteredCountries
                    CountryRow {
                      required property var modelData
                      required property int index
                      width: locationColumn.width
                      country: modelData
                      rowIndex: index
                    }
                  }
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

  component CountryRow: CursorSurface {
    id: countryRow
    property var country: null
    property int rowIndex: 0
    readonly property string countryName: country ? String(country.name || "Unknown") : "Unknown"
    readonly property string countryCode: country ? String(country.code || "") : ""
    readonly property string countryFlag: vpn.countryFlagEmoji(countryCode)
    readonly property bool expanded: root.expandedCountryCode === countryCode
    readonly property var cities: (vpn.citiesByCountry && vpn.citiesByCountry[countryCode]) || null
    readonly property bool citiesLoading: vpn.citiesLoadingCode === countryCode

    hasCursor: root.cursorActive && root.focusSection === "locations" && root.locationIndex === rowIndex
    foreground: root.foreground
    implicitHeight: countryColumn.implicitHeight + Style.spacing.rowPaddingX

    // Declared before the interactive Column below so the button/city rows
    // (drawn on top) get first claim on clicks — this one only fires for
    // whatever space they don't cover.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setLocationCursor(countryRow.rowIndex)
      onClicked: vpn.connectLocation(countryRow.countryCode, "")
    }

    Column {
      id: countryColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          // Most-compatible way to show a flag without shipping image assets
          // (matches the rest of this plugin's icons, all native-drawn/text,
          // no external SVGs) - falls back to nothing (just extra spacing,
          // not a broken glyph) on a code that doesn't map to a flag.
          text: countryRow.countryFlag
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          visible: text !== ""
        }

        Text {
          Layout.fillWidth: true
          text: countryRow.countryName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          text: countryRow.countryCode
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelActionButton {
          iconText: countryRow.expanded ? "▾" : "▸"
          tooltipText: "Cities"
          foreground: root.foreground
          fontFamily: root.fontFamily
          Layout.alignment: Qt.AlignVCenter
          onClicked: root.toggleExpandedCountry(countryRow.countryCode)
        }
      }

      Column {
        visible: countryRow.expanded
        width: parent.width
        spacing: Style.space(2)
        leftPadding: Style.space(16)

        Text {
          visible: countryRow.citiesLoading
          text: "Loading cities…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          visible: !countryRow.citiesLoading && countryRow.cities !== null && countryRow.cities.length === 0
          text: "No cities listed."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: countryRow.cities || []
          Text {
            required property var modelData
            width: countryColumn.width - Style.space(16)
            text: String(modelData.name || "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: vpn.connectLocation(countryRow.countryCode, String(modelData.name || ""))
            }
          }
        }
      }
    }
  }
}
