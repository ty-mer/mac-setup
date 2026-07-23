# Mac Setup

A one-click setup for a fresh macOS install to my specifications: Homebrew, apps, and
system preferences get configured automatically, then a series of guided steps walk
you through anything that needs a click or a login.

## What's here

- `fresh-install.sh` — the orchestrator. Run this one.
- `Brewfile` — Homebrew formulae and casks.
- `macos-defaults.sh` — system preference tweaks (`defaults write`, `pmset`,
  `PlistBuddy`, etc). Called by `fresh-install.sh`, not meant to be run on its own.

## Running it

Clone this repo (or download all three files into the same directory — they need
to sit next to each other), then:

```
./fresh-install.sh
```

It runs in two phases:

1. **Phase A — automated.** Homebrew, packages from the Brewfile, and every system
   preference that can be set with zero clicking. Runs top to bottom, no
   supervision needed.
2. **Phase B — guided manual steps.** A dialog walks through anything that
   genuinely needs a click, sign-in, or permission grant — one step at a time,
   grouped by app, with an Open button to jump to the right place and a Done
   button to move on.

## Status

Still actively shaping this as I set up machines — expect things to move, get
renamed, or get reordered for a while yet. This README will fill in with more
detail (what's installed, what's still manual and why, known rough edges) as it
settles down.
