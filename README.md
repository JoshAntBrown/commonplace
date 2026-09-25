# Commonplace

A native macOS canvas for collecting references, snippets and notes — stickies, markdown notes,
links, images and videos — and connecting them into a map of ideas.

## Run

```sh
scripts/run.sh            # debug build → build/Commonplace.app, then launch
scripts/build-app.sh      # release build
```

Open `Package.swift` in Xcode to work on it there.

## Data

Everything lives in `~/Commonplace/<Board>/`:

- `cards/*.md` — one Markdown file per card, with YAML front-matter (kind, title, url, colour…)
- `board.json` — positions, sizes, connections and viewport
- `assets/` — images dropped or pasted onto the board

Markdown files dropped into `cards/` by hand appear on the board on next open.

## Browser

Press **B** (or the globe button) for a browser beside the canvas. Search the web or images
(DuckDuckGo), then drag images, links or videos onto the board, or right-click for
**Add Image / Link / Selection / Page to Board**. Clipped images are saved into `assets/` and
remember their `source`; selected text becomes a quote note linking back to its page.

## Breadboards

Press **P** for a place card (Shape Up breadboarding): an underlined name, then one affordance per
line. Click the dot beside an affordance, then click a place, to draw the connection from that
affordance. Connections remember which affordance they start from (`fromItem` in `board.json`).

## Video

- YouTube: embedded via the IFrame API.
- X posts: the MP4 behind the post is resolved and played natively (AVKit).
- Vimeo and other pages: loaded in a web view.

Press **T** (or **+ Moment**) on a selected video to add a moment: a sticky stamped with the
current time, stacked beside the video and connected to it. Click its timestamp to jump back;
connect it to anything else like any other card.

Click **1×** in a video's title bar to step through speeds (hold for the full list), or use **[** and **]**.
Each video remembers its speed and where you left off (`speed:` and `position:` in its front-matter).
