# ProtonVPN Omarchy Widget

Native Omarchy bar widget for ProtonVPN.

## Features

- Shows ProtonVPN connection state in the bar (connected / connecting / disconnected / needs sign-in)
- Left click opens a keyboard-friendly panel
- Right click toggles the connection on/off
- Middle click refreshes status
- Connect to the fastest server, or disconnect, from the panel
- Pick a specific country (and optionally a city) to connect to
- See the connection's server, load, protocol, tunnel IP, and public IP
- Sign in or sign out of your ProtonVPN account

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor between the connect switch, the
  location picker toggle, its country list, and the account row
- `enter` / `space`: activate the current row (toggle connection, open the
  location picker, connect to the selected country, sign in/out)
- `t`: toggle the connection
- `esc`: close the panel, or close the location search field
- Typing in the location search box filters the country list; the city list
  under each country is mouse-only (click the chevron to expand)

## Requirements

- `protonvpn` CLI on `PATH` (package `proton-vpn-cli`)
- The ProtonVPN daemon running, so `connect`/`disconnect`/`status` don't need `sudo`
- `curl` on `PATH` for the optional public-IP lookup (skipped silently if it fails)
- An existing ProtonVPN sign-in; the panel can trigger sign-in but assumes
  you already have a ProtonVPN account

## Icon

Two connected nodes (this device and the server) joined by a routed line,
drawn as flat-polygon `QtQuick.Shapes` paths — no image assets, no shield.
Four states, carried by two tones of the same color:

- **Connected** — solid nodes, unbroken route
- **Connecting** — solid nodes, route animating as marching dashes
- **Disconnected** — the whole mark dimmed, route broken with a gap
- **Needs sign-in** — two solid nodes, no route between them at all

## Install

```
omarchy plugin add https://github.com/AntouanK/omarchy-protonvpn --enable --yes
```

## Files

- `manifest.json` - plugin metadata, bar-widget registration
- `Service.qml` - drives the `protonvpn` CLI (status/info polling, connect/disconnect, sign-in/out, country/city lists, tunnel/public IP lookup)
- `Panel.qml` - the popup UI and keyboard navigation
- `Icon.qml` - the bar icon (native QtQuick.Shapes, no image assets)
- `Model.js` - pure CLI-output parsing, no side effects
