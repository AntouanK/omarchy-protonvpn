import QtQuick
import QtQuick.Shapes

// ProtonVPN mark: two nodes joined by a routed line — this device, bottom
// left; the server it tunnels to, top right; and a stepped path between them.
// Drawn as flat straight-edged polygons the same way DropboxIcon.qml draws
// its diamonds, because that is the only technique that survives the bar's
// real render size.
//
// WHY NODES AND NOT A SHIELD. Two earlier rounds put a shield here. A shield
// is generic security iconography — firewalls, antivirus and password
// managers all use it — so it says "something is protected" without ever
// saying VPN. A routed line between two points says the thing a VPN actually
// does: your traffic leaves here and comes out over there. It is also
// deliberately not Tailscale's fixed 3x3 dot grid, which stands for a mesh:
// this is one path between two endpoints, not a lattice.
//
// The bar slot is Style.space(11), i.e. about ELEVEN REAL PIXELS. Every shape
// below is authored on an 11x11 grid where one grid unit is one bar pixel,
// and was checked by rendering this exact geometry offscreen at 11, 14, 18
// and 24 px and reading it back pixel by pixel — no shape here produces a
// single anti-aliased grey pixel at any of those sizes. What died at that
// size across the three rounds, and must not come back:
//  1. A shield drawn as a thin stroked outline — anti-aliasing filled the
//     interior in and it became a solid dark blob.
//  2. A padlock (ring shackle + body): the shackle's hole is a thin cutout,
//     and cutouts under about 3px close up and blob.
//  3. A diagonal "crossed out" bar for the off state, and by the same
//     argument any diagonal connector between nodes — a line that is not
//     axis-aligned can never land on the pixel grid, so it smears. Every
//     link below is therefore horizontal or vertical, which is also how
//     network diagrams route anyway.
//  4. A centred T-shaped aerial over a shield: it read as a shovel. A
//     symmetric mast on the centreline reads as a pin or a thumbtack.
//  5. A three-node bus (two endpoints joined along the bottom, a third node
//     dropping onto the line from above) — at 11px the stem plus crossbar
//     read as a TV aerial or a hammer, not a network.
//  6. Nodes at 4 of 11 units: the two blocks swamp the route between them
//     and the mark stops being a path and becomes two lumps. 3 units is the
//     largest node that still leaves the line room to read.
//  7. A plain single-elbow route (out along the bottom, up the right side).
//     It renders cleanly but a right angle with a blob at each end reads as
//     a corner bracket or a return arrow. The extra step in the Z below is
//     what makes it read as a route with a hop in it.
//  8. Dashing the WHOLE route for the connecting state. The two horizontal
//     legs are about three pixels long in the bar — shorter than one dash —
//     so at most offsets they vanished and the mark collapsed into a floating
//     dotted stalk between two blocks. Only the riser, eight of the eleven
//     units tall, is long enough to hold dashes and show them travelling.
//
// State is carried by two tones of the SAME colour — full opacity and a dim
// alpha — plus the presence and continuity of the route. No second hue, no
// red badge:
//   connected    solid nodes + unbroken route     dense, obviously joined
//   connecting   solid nodes + dashes up the riser the link is being laid
//   disconnected everything dim, route cut in two a visible break mid-riser
//   needsLogin   solid nodes, no route at all     two lit endpoints, no link
// needsLogin deliberately keeps the nodes at FULL opacity: at 11px the route
// is a one-pixel line, far too little ink to carry a state by fading alone,
// whereas two solid blocks with nothing between them is unmissable and reads
// as "both ends exist, there is no session".
//
// The connecting riser is the one place a STROKE is used instead of a filled
// polygon, because dashes are a stroke feature — but it is still crisp: an
// axis-aligned stroke whose centreline sits at a whole pixel plus half the
// stroke width covers exactly the same column the filled version does. Its
// dashOffset is animated so the dashes march up the riser, away from this
// device, which is what makes the state read as "in progress" rather than
// just "a different line style". The animation is bound to the state, so it
// runs only while connecting and never idles in the background.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // The state inputs, mirroring the service's own flags directly so call
  // sites don't have to translate them into a presentation vocabulary.
  property bool active: false
  property bool needsLogin: false
  property bool connecting: false

  // Dim tone. Low enough to read as "off" at a glance beside the solid state,
  // high enough to still show a silhouette on both light and dark themes.
  readonly property real dimAlpha: 0.35

  // Exactly one of these is true at a time. Sign-in wins over everything: a
  // tunnel that cannot authenticate is not pending, it is blocked. `active`
  // is set optimistically by the service the instant a connect is asked for,
  // so `pending` is what separates "asked for" from "confirmed up".
  readonly property bool signedOut: needsLogin && !active
  readonly property bool pending: connecting && !signedOut
  readonly property bool linked: active && !pending
  // Plain "off": the only state that shows the route cut in two.
  readonly property bool severed: !linked && !pending && !signedOut

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  // --- geometry -------------------------------------------------------------
  // Fractions are the 11x11 design grid divided through, and every edge is
  // rounded to a whole pixel. The nodes sit hard in opposite corners so the
  // mark uses the full box; the route's legs are centred on each node so the
  // line leaves and enters through the middle of a block rather than clipping
  // its corner.
  readonly property int s: Math.round(iconSize)
  readonly property int node: Math.max(2, Math.round(s * 3 / 11))   // 3 of 11
  readonly property int lineW: Math.max(1, Math.round(s / 11))      // 1 of 11

  // Row through the centre of the bottom-left node, row through the centre of
  // the top-right node, and the column the riser climbs.
  readonly property int rowLo: Math.round(s - node / 2 - lineW / 2)
  readonly property int rowHi: Math.round(node / 2 - lineW / 2)
  readonly property int riser: Math.round(s / 2 - lineW / 2)

  // The break shown while disconnected, centred in the riser. Two grid units
  // is the smallest gap that still reads as a gap and not as a rendering
  // artefact at 11px.
  readonly property int gap: Math.max(2, Math.round(s * 2 / 11))
  readonly property int gapTop: Math.round((rowHi + rowLo + lineW) / 2 - gap / 2)

  // Dash geometry for the connecting state, in multiples of the stroke width.
  // The riser is eight grid units tall, so a two-on/one-off pattern gives it
  // roughly three dashes: enough to read as a dotted link and enough for the
  // eye to track them moving, without thinning to the grey mush a one-pixel
  // on/off pattern turns into once the offset lands between pixels.
  readonly property real dashOn: 2
  readonly property real dashOff: 1

  // A 1px line is only crisp if our own origin sits on a whole pixel.
  // `anchors.centerIn` inside a parent of the opposite parity puts us on a
  // half pixel and smears it across two columns; nudge what we draw back onto
  // the grid. This is a render-time transform, so it does not affect layout.
  transform: Translate {
    x: Math.round(root.x) - root.x
    y: Math.round(root.y) - root.y
  }

  // The two endpoints. Their own layer so they can stay solid while the route
  // fades or disappears underneath them.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    opacity: (root.linked || root.pending || root.signedOut) ? 1.0 : root.dimAlpha

    // This device: bottom-left.
    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: 0
      startY: root.s - root.node
      PathLine { x: root.node; y: root.s - root.node }
      PathLine { x: root.node; y: root.s }
      PathLine { x: 0; y: root.s }
      PathLine { x: 0; y: root.s - root.node }
    }

    // The server: top-right.
    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.s - root.node
      startY: 0
      PathLine { x: root.s; y: 0 }
      PathLine { x: root.s; y: root.node }
      PathLine { x: root.s - root.node; y: root.node }
      PathLine { x: root.s - root.node; y: 0 }
    }
  }

  // The route: out of the low node, up the middle, into the high node. One
  // layer for all three legs so the corners composite once, with no seam and
  // no doubled-up dim patch where they overlap.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: !root.signedOut
    opacity: (root.linked || root.pending) ? 1.0 : root.dimAlpha

    // Out of the bottom-left node, rightwards to the riser. The two short
    // legs stay solid in every state that draws a route at all, including
    // while connecting — they are barely three pixels long in the bar, far
    // too short to hold a dash, and leaving them solid is what keeps the Z
    // recognisable while the riser is busy marching.
    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.node
      startY: root.rowLo
      PathLine { x: root.riser + root.lineW; y: root.rowLo }
      PathLine { x: root.riser + root.lineW; y: root.rowLo + root.lineW }
      PathLine { x: root.node; y: root.rowLo + root.lineW }
      PathLine { x: root.node; y: root.rowLo }
    }

    // The riser. While disconnected it stops short of the top, leaving the
    // gap; the stub above the gap is drawn by the next path. While connecting
    // it is not drawn here at all — the dashed, animated copy below stands in
    // for it.
    ShapePath {
      fillColor: root.pending ? "transparent" : root.color
      strokeWidth: 0
      startX: root.riser
      startY: root.severed ? (root.gapTop + root.gap) : root.rowHi
      PathLine { x: root.riser + root.lineW; y: root.severed ? (root.gapTop + root.gap) : root.rowHi }
      PathLine { x: root.riser + root.lineW; y: root.rowLo + root.lineW }
      PathLine { x: root.riser; y: root.rowLo + root.lineW }
      PathLine { x: root.riser; y: root.severed ? (root.gapTop + root.gap) : root.rowHi }
    }

    // Upper stub of a broken riser — drawn only in the disconnected state.
    ShapePath {
      fillColor: root.severed ? root.color : "transparent"
      strokeWidth: 0
      startX: root.riser
      startY: root.rowHi
      PathLine { x: root.riser + root.lineW; y: root.rowHi }
      PathLine { x: root.riser + root.lineW; y: root.gapTop }
      PathLine { x: root.riser; y: root.gapTop }
      PathLine { x: root.riser; y: root.rowHi }
    }

    // Into the top-right node.
    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      startX: root.riser
      startY: root.rowHi
      PathLine { x: root.s - root.node; y: root.rowHi }
      PathLine { x: root.s - root.node; y: root.rowHi + root.lineW }
      PathLine { x: root.riser; y: root.rowHi + root.lineW }
      PathLine { x: root.riser; y: root.rowHi }
    }
  }

  // The riser again, stroked and dashed, for the moment between asking for a
  // connection and the CLI confirming one. Only the riser: it is the one leg
  // long enough (eight of the eleven grid units) to hold several dashes and
  // show them travelling. Its centreline sits half a stroke width off the
  // whole-pixel grid, which is exactly what puts the stroke back on the same
  // column the filled riser above occupies.
  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    visible: root.pending

    ShapePath {
      id: pendingRiser
      fillColor: "transparent"
      strokeColor: root.color
      strokeWidth: root.lineW
      strokeStyle: ShapePath.DashLine
      // In multiples of strokeWidth, so the dashes stay in proportion at
      // every icon size. Square ends: nothing rounded.
      dashPattern: [root.dashOn, root.dashOff]
      capStyle: ShapePath.FlatCap
      startX: root.riser + root.lineW / 2
      startY: root.rowLo + root.lineW / 2
      PathLine { x: root.riser + root.lineW / 2; y: root.rowHi + root.lineW / 2 }
    }
  }

  // Marching dashes: one full pattern period per cycle, counting down so the
  // dashes travel up the riser — away from this device, towards the server —
  // rather than back down it. Bound to the state and to being on screen, so
  // it starts when the connect is requested, stops the instant the service
  // confirms or gives up, and never burns a frame callback while the icon is
  // idle. The offset is reset on stop so the next connect starts from the
  // same phase rather than wherever the last one happened to end.
  NumberAnimation {
    target: pendingRiser
    property: "dashOffset"
    from: root.dashOn + root.dashOff
    to: 0
    duration: 700
    loops: Animation.Infinite
    running: root.pending && root.visible
    onRunningChanged: if (!running) pendingRiser.dashOffset = 0
  }
}
