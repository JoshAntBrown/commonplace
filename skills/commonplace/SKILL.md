---
name: commonplace
description: Work with the user's Commonplace boards (their visual thinking canvas of stickies, notes, links, videos, images and breadboards) through the commonplace MCP tools. Use when the user mentions Commonplace, their board or canvas, cards, stickies, moments on a video, or asks you to find, add, connect, summarise or explore ideas on a board.
---

# Commonplace

Commonplace is the user's canvas for thinking. A **board** holds **cards** joined by
**connections** (arrows, optionally labelled). It's a space for exploring ideas, not a document
to keep tidy. Treat it the way you'd treat someone's notebook: add to it, don't rearrange it.

Card kinds:
- **sticky**: a quick thought. Stickies can stay stickies forever; don't "process" them.
- **note**: a longer, titled Markdown note.
- **link / video / image**: references, usually with a `source`. Videos are YouTube or X posts.
- **place**: a Shape Up breadboard place. `title` is the place, each `body` line an affordance.
  Connections can start from one affordance (`from_affordance`).

A **thought** is a sticky drawn out of another card (`thought_of`). A thought on a video is a
**moment**: its body starts with a timestamp like `[12:34]` that seeks the video when clicked.

## Working on a board

1. **Look before you act.** Call `get_selection` first: what the user has selected is almost
   always what they mean by "this". Use `get_board` or `search` for the wider context.
2. **Add, don't rewrite.** Put your contribution in new cards:
   - Respond to a card with `add_thought`, which places and connects a sticky beside it.
   - Use `add_card` with `near` and `connect_from` for anything else related.
   - When you do change a card, prefer `update_card` with `append` over replacing the text.
3. **Keep the user's words.** Don't reword, merge or delete their cards unless they ask.
   `delete_card` is only for explicit requests.
4. **Keep provenance.** Bring web material in with `clip_url` (videos, links and images keep their
   source). When you summarise, link or name what you drew on.
5. **Say why things connect.** Label connections with the relationship ("supports",
   "in tension with", "example of") when it isn't obvious.
6. **Show, don't just tell.** After adding something the user should look at, `focus_card` it.

Everything you do is undoable in the app with ⌘Z. Say so if you've made a large change.

## Recipes

- **Summarise a talk from its moments:** `get_video_moments` on the video, then write one note
  near it (`add_card` kind `note`, `near` the video, `connect_from` the video) that pulls the
  moments together, citing timestamps like `[12:34]`.
- **Find related ideas:** `search` across all boards for the key terms, then `connect` genuinely
  related cards on the same board, with a label. Mention relevant cards on other boards in your
  reply rather than copying them over.
- **Research a concept:** find good sources on the web, `clip_url` the best one or two near the
  relevant card, and add a short `add_thought` explaining why each matters.

## Tips

- Omit `board` to act on the board on screen. Card ids can be shortened to a unique prefix.
- Positions are canvas coordinates (x right, y down). You rarely need them: `near` places cards
  sensibly.
- Don't edit the Markdown files under `~/Commonplace` directly while the app is running; use the
  tools so changes appear live and stay undoable.
