# mm2-coin-farmer

Personal automation script for an MM2-style coin-collection round.

## Files

- `TweenToCoins.lua` — the main script. Designed to be loaded via
  `loadstring(...)()` from the local Volt autoexec folder.

## Local loader

The autoexec entry on the local machine is `loader.lua` (not in this
repo — kept locally to avoid committing the PAT). It fetches and
executes this repo's `TweenToCoins.lua` via the GitHub Contents API
with an Authorization header.
