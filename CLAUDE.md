# Commonplace

A native macOS canvas for thinking: collect references (links, YouTube/X videos, images, clipped
quotes), jot stickies and notes, sketch Shape Up breadboards, and connect it all. Keyboard-first
and themeable in the spirit of Omarchy. A Linux version may come one day; nothing depends on it yet.

## Build & run

```sh
scripts/run.sh          # debug build → build/Commonplace.app, relaunches the app
scripts/build-app.sh    # release build
swift build             # compile only
```

Swift Package (tools 5.10, Swift 5 language mode), macOS 14+, no Xcode project. The app bundle is
assembled by `scripts/build-app.sh` from `Support/Info.plist` and ad-hoc signed. Quit the app
before relaunching (`osascript -e 'tell application id "com.joshbrown.commonplace" to quit'`) so
it saves cleanly.

## Data

User data lives in `~/Commonplace/<Board>/` (never in the repo): `cards/*.md` (Markdown with
YAML front-matter, one per card), `board.json` (layout, connections, viewport), `assets/` (images).
Hand-written `.md` files dropped into `cards/` load onto the board. Keep the format readable and
Obsidian-friendly; add front-matter keys rather than inventing sidecar files. Test against the
"Breadboard Example" board, not the user's own boards.

## Code map (`Sources/Commonplace/`)

- `Models.swift`: `Card`, `CardKind`, `Connection`, `Place` breadboard metrics, `Timestamp`
- `Storage.swift`: `Library` (boards on disk), `CardFile` front-matter encode/decode, seed board
- `BoardStore.swift`: all board state and operations: add/update, drag/resize, connections,
  thoughts & moments, clipping, undo/redo snapshots, autosave
- `CanvasView.swift`: canvas, gestures, marquee, NSEvent monitors for keys/scroll/pinch,
  connection drawing, help overlay
- `CardView.swift`: per-kind card rendering and editing
- `Web.swift`: video sources (YouTube iframe API, X MP4 via syndication API, pages), players,
  link metadata. `Browser.swift`: in-app browser panel and clipping
- `MarkdownText.swift`: lightweight Markdown renderer with inline timestamp chips
- `Theme.swift`: theme palettes

## Conventions

- Content (text, images, video) scales with zoom (`s`); chrome (title bars, badges, corners,
  lines) is capped at 100% (`c = min(scale, 1)`). Don't use `scaleEffect` on cards: AppKit views
  inside (web views, players, text editors) must be laid out at real size.
- SwiftUI gestures can be cancelled without `onEnded`: key sessions by start location and reset
  with `@GestureState`.
- User-facing mutations call `checkpoint()` first for undo; background updates (metadata,
  playback progress) must not.
- Canvas shortcuts live in the key monitor in `CanvasView`; they must step aside when a text view,
  web view or video player has focus.

## Design principles

- A general tool for thinking, not a tool for any one method. Zettelkasten, Christopher
  Alexander's pattern languages, Shape Up breadboarding and others are inspirations and tools in
  the toolbox, never the app's identity. Prefer general features that many methods can use
  (templates, connection types, zoom behaviour) over method-specific modes.
- Methods are inspirations, not workflows. Stickies can stay stickies forever: no inboxes,
  counts or nudges to "process" notes. Conversions (e.g. sticky → note) are optional affordances.
- Structure-preserving (after Alexander): good interactions let a board grow piecemeal,
  strengthening what's there rather than forcing reorganisation. Drawing a thought out of a card
  is the model.
- Everything is a first-class card that can be connected: moments and thoughts are stickies, not
  fields inside other cards.
- Keyboard-first: every common action has a single-key shortcut on the canvas.
