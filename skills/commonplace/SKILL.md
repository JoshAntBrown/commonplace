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

There are two kinds of link, and the difference matters (it comes from Luhmann's Zettelkasten and
Alexander's pattern languages):

- **Sequence link: `parent`.** The card this one follows from, elaborates or forms part of. Each
  card has at most one parent, so a board is a set of trees. The trees give a board its order:
  they're drawn as solid lines, tidied into columns and read in sequence. Set with `parent` on
  `add_card`, `add_thought`, or `set_parent`.
- **Reference: a connection.** "This relates to that", between any two cards, anywhere. Shown as
  a chip on the card, with lines only for the card the user has selected; references that are off
  screen float beside it. Made with `connect`.
- **Breadboard wires** are the exception: a connection from a place's affordance
  (`from_affordance`), or between two places, is part of the diagram ("this leads there"). Wires are
  always drawn and aren't references.

Use a parent when a card grows out of another (a point from a talk, a consequence, a sub-part, the
next step). Use a reference for everything else (supports, contradicts, example of, same idea as).
When in doubt, a card has one natural parent and any number of references.

A **thought** is a sticky that follows from another card (`add_thought`). A thought on a video is
a **moment**: its body starts with a timestamp like `[12:34]` that seeks the video when clicked.

## Working on a board

1. **Look before you act.** Call `get_selection` first: what the user has selected is almost
   always what they mean by "this". Use `get_board` or `search` for the wider context.
2. **Add, don't rewrite.** Put your contribution in new cards:
   - Respond to a card with `add_thought`, which places a sticky that follows from it.
   - Use `add_card` with `parent` when a card elaborates another, or `near` plus `connect` for a
     looser relationship.
   - When you do change a card, prefer `update_card` with `append` over replacing the text.
3. **Keep the user's words.** Don't reword, merge or delete their cards unless they ask.
   `delete_card` is only for explicit requests.
4. **Keep provenance.** Bring web material in with `clip_url` (videos, links and images keep their
   source). When you summarise, link or name what you drew on.
5. **Say why things connect.** Label connections with the relationship ("supports",
   "in tension with", "example of") when it isn't obvious.
6. **Show, don't just tell.** After adding something the user should look at, `focus_card` it.

Everything you do is undoable in the app with ⌘Z. Say so if you've made a large change.

## Keep the board calm

A board is read visually. A pile of cards joined by long crossing lines is noise, however good
each card is.

- **Build trees, not scatter.** Give each new card the `parent` it grows out of, so related ideas
  form a branch. Several points from one source are siblings under it. After adding a batch, call
  `tidy` on the card you built from so the new branch is laid out cleanly. Never tidy the user's
  existing arrangement unless they ask.
- **Reference sparingly.** Draw only the strongest cross-links, usually one or two per card. If a
  card mostly belongs somewhere else, give it that parent instead of a long line across the board.
- **Short labels.** One to three words ("supports", "example of", "tension"), or none when the
  relationship is obvious.
- **Fewer, better cards.** Several points on one idea belong in one note with a list, not five
  stickies. Stickies are for single, quick thoughts.
- **Big batches:** if you're adding more than about eight cards, say so first and suggest the
  user look at them with `focus_card` as you go.

## Recipes

- **Summarise a talk from its moments:** `get_video_moments` on the video, then write one note
  with the video as its `parent` that pulls the moments together, citing timestamps like `[12:34]`.
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
