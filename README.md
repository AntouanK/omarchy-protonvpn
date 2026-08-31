# ProtonVPN Omarchy Widget

Native Omarchy bar widget for ProtonVPN.

## Features

- Shows ProtonVPN connection state in the bar (connected / connecting / disconnected / needs sign-in)
- Left click opens a keyboard-friendly panel
- Right click toggles the connection on/off
- Middle click refreshes status
- Connect to the fastest server, or disconnect, from the panel
- Browse country → city → individual server, and connect at any level
- See per-country server and city counts, per-city server counts, and the
  live load of every server, colour-coded, so you can pick a quiet one
- P2P / Tor / Secure Core badges, with Secure Core servers showing which
  country they enter through
- Pin countries and servers to the top of the list, and reconnect from a
  Recent tab of the last 20 places you connected to
- See the connection's server, load, protocol, tunnel IP, and public IP
- Sign in or sign out of your ProtonVPN account

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor between the connect switch, the
  location picker toggle, its location list, and the account row
- `l` / `h` or left/right arrows: expand and collapse the row under the
  cursor — a country into its cities, a city into its servers
- `p`: pin or unpin the row under the cursor
- `l` / `h` on the LOCATIONS row itself: switch between the All and Recent tabs
- `enter` / `space`: activate the current row (toggle connection, open the
  location picker, connect to the selected country/city/server, sign in/out)
- `t`: toggle the connection
- `esc`: close the panel, or close the location search field
- Typing in the location search box filters the country list

## Requirements

- `protonvpn` CLI on `PATH` (package `proton-vpn-cli`)
- The ProtonVPN daemon running, so `connect`/`disconnect`/`status` don't need `sudo`
- `curl` on `PATH` for the optional public-IP lookup (skipped silently if it fails)
- `jq` on `PATH` for server counts, load figures and the per-city server
  lists (a hard dependency of the `omarchy` package itself, so it is already
  installed). Without it, the picker still lists and connects to countries —
  it just shows no server detail.
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
- `Service.qml` - drives the `protonvpn` CLI (status/info polling, connect/disconnect, sign-in/out, country list, tunnel/public IP lookup), reads the server cache via jq, and persists pins/recents
- `Panel.qml` - the popup UI and keyboard navigation
- `Icon.qml` - the bar icon (native QtQuick.Shapes, no image assets)
- `Model.js` - pure parsing, the two jq programs, and the recents/pins rules;
  no side effects, so it stays testable outside Quickshell

## Persisted state

Pins, the recent list, and a cached copy of the country list live in:

```
$XDG_STATE_HOME/omarchy/protonvpn-state.json
```

The country list is cached because `protonvpn countries list` is a network
round-trip taking seconds — with a cache the picker has something to show the
moment it opens, and refreshes behind it only when the copy is over six hours
old. A connection is added to the recent list when it *succeeds*, not when
it is clicked, so a failed attempt does not end up at the top of your history.

## Where the server detail comes from

The `protonvpn` CLI cannot report it: `protonvpn servers` only prints a link
to protonvpn.com, `countries list` gives names and codes, and `cities list`
gives cities and features. Proton's own API is not an option either — it
rejects stale `x-pm-appversion` headers outright and requires an access token
for the server list.

So the panel reads the cache the ProtonVPN daemon already maintains:

```
$XDG_CACHE_HOME/Proton/VPN/serverlist.json
```

That file holds every logical server with its name, load, city, tier, status
and feature flags. Two `jq` programs (see `Model.js`) roll it up — one for the
country summaries, one for a single country's cities and servers — so the
~24MB file is never parsed inside the shell. Loads carry Proton's own expiry
stamp, and the panel says so when they are past it. If the cache is missing,
which it is until the daemon has run once while signed in, the picker quietly
falls back to plain country names.
