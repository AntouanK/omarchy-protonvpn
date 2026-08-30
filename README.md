# ProtonVPN Omarchy Widget

Native Omarchy bar widget for ProtonVPN, modeled on the first-party
Tailscale widget.

## Features

- Shows ProtonVPN connection state in the bar (connected / disconnected / needs sign-in)
- Left click opens a keyboard-friendly panel
- Right click toggles the connection on/off
- Middle click refreshes status
- Connect to the fastest server, or disconnect, from the panel
- Pick a specific country (and optionally a city) to connect to
- See the connection's server/load/protocol, tunnel IP, and public IP
- Sign in or sign out of your ProtonVPN account

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor between the connect switch, the
  location picker, its country list, and the account row
- `enter` / `space`: activate the current row (toggle connection, open the
  location picker, connect to the selected country, sign in/out)
- `t`: toggle the connection
- `esc`: close the panel, or close the location search field
- Typing in the location search box filters the country list; the city list
  under each country is mouse-only (click the chevron to expand)

## Requirements

- `protonvpn` CLI on `PATH` (package `proton-vpn-cli`)
- The ProtonVPN daemon (`proton.vpn.daemon`) running, so `connect`/`disconnect`/`status`
  don't need `sudo`
- `curl` on `PATH` for the optional public-IP lookup (skipped silently if it fails)

## Signing in

`protonvpn signin` requires a masked password typed at a real terminal — there
is no non-interactive flag. Choosing "Sign in" from the panel opens a terminal
window for you to enter your username and password; the widget's normal
status poll picks up the new signed-in state on its own once you finish.

## Signing out

"Sign out" runs `protonvpn signout` directly (it's headless and safe), which
clears your local ProtonVPN credentials.

## Choosing a location

Expand "Choose location" in the panel to search and pick a country — selecting
one runs `protonvpn connect --country <code>`. Expand a country's chevron to
load its cities and connect to a specific one (`--city <name>` added to the
same command). The one-click hero switch still connects to the fastest server
overall and remains the primary action; the picker is a secondary section.

## Connection details

While connected, the panel shows the server, its load and protocol (from
`protonvpn status`), the tunnel's local IP (read from the `proton0` — falling
back to `tun0` — interface via `ip addr`), and a cached public IP (one
`curl https://ifconfig.me` per connection, best-effort).

## Icon

Two connected nodes (this device and the server) joined by a routed line,
drawn with straight-edged `QtQuick.Shapes` paths — the same flat-polygon
technique the built-in Dropbox icon uses, chosen because curves and thin
strokes anti-alias into an illegible blob at real bar-icon size (~11-18px
depending on monitor scale). Four states, two tones (the theme foreground
color plus an alpha-dimmed variant of it, no other hue):

- **Connected** — solid nodes, unbroken route.
- **Connecting** — solid nodes and legs, with the vertical leg of the route
  animating as marching dashes until the connection is confirmed.
- **Disconnected** — the whole mark dimmed, with a gap broken into the route.
- **Needs sign-in** — two solid (undimmed) nodes with no route between them
  at all, rather than a fainter version of the connected mark.

## Reliability

`protonvpn status` calls out to Proton's API for the live server list
whenever a connection is active, and `info` can hit the API too — so either
can occasionally fail on a transient network blip, not just a real state
change. The widget tolerates a few consecutive poll failures (keeping the
last known-good state and quietly retrying) before it ever shows
"Unavailable" or "needs sign-in", and only trusts an immediate "needs
sign-in" when the CLI's own output says so explicitly.

## Add to the bar

Install this plugin under `~/.config/omarchy/plugins/antouank.protonvpn/`,
then run `omarchy-shell shell rescanPlugins` and
`omarchy plugin enable antouank.protonvpn --section right`.
