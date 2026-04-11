# MEMORY INDEX

Pointers to active memories. The index loads into agent context at session start; the body of each memory file lives under `memory/active/`.

## Format

```
- [<title>](active/<file>.md) — <one-line hook>
```

Keep entries to one line. The index is meant to be scanned, not read.

## Active

> Add entries as candidates are promoted from `PROMOTION_QUEUE.md`.

## Promoted (archive)

Promoted entries that are no longer active live under `memory/promoted/`. Stale entries live under `memory/stale/`. Rejected candidates live under `memory/rejected/`.
