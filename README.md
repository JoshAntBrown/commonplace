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

## Copy and paste

**⌘C** copies the selected cards (with their layout, and the threads and references among them),
**⌘V** pastes them under the pointer on any board, **⌘X** cuts, **⌘D** duplicates. Images come with
them between boards, and other apps receive the cards' Markdown.

## Vocabulary

- **Card**: anything on a board (sticky, note, link, video, image, place).
- **Thread**: the "follows from" link (`parent:` in front-matter). One per card, so a board is a set
  of trees, drawn as solid curves. **A** tidies the selected thread into columns.
- **Thought** (**T**): a sticky drawn out of the selection and threaded to it; on a video it starts
  with the current time, which seeks the video when clicked. **Continue** (**⇧T**): the next card in
  the same thread. **⇧C** then a click makes that card follow the selection.
- **Reference** (**C** then a click): "see also". Shown as a chip on the card and a floating list
  beside the selected card, not as lines (**R** draws them all). Right-click converts to a thread.
- **Wire**: a breadboard link from a place's affordance to a place; always drawn.

Deleting a card moves its children up to its parent. Older `thought-of` / `moment-of` keys load as
`parent`.

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

Press **T** (or **+ Thought**) on a selected video to add a thought at the current time: a sticky
starting with the timestamp, threaded from the video. Click the timestamp to jump back.

Click **1×** in a video's title bar to step through speeds (hold for the full list), or use **[** and **]**.
Each video remembers its speed and where you left off (`speed:` and `position:` in its front-matter).

## Agents

Commonplace runs an MCP server (Streamable HTTP) inside the app at `http://127.0.0.1:7717/mcp`,
so agents work on the live boards: changes appear on the canvas and can be undone with ⌘Z.
It only listens on this machine, needs the bearer token in `~/Commonplace/.mcp-token`, and refuses
requests from web pages.

- **Terminal panel** (⌃\` or the terminal button): a shell in `~/Commonplace`. Run `claude` there
  and it picks up the server (`.mcp.json`) and the skill (`.claude/skills/commonplace`).
- **Anywhere else:** Agents → Copy Claude Code Setup Command, then paste it in a terminal. Agents →
  Install Skill for Claude Code puts the skill in `~/.claude/skills/commonplace`.
- The skill lives in `skills/commonplace/SKILL.md` and ships inside the app bundle.

Tools: list_boards, get_board, get_card, search, get_selection, get_video_thoughts, add_card,
add_thought, update_card, add_reference, set_thread, tidy_thread, clip_url, delete_card, create_board,
focus_card.

Files edited outside the app (another editor, a script) are picked up and reloaded.
