# Planning

Upcoming features and API design notes. Nothing here is implemented yet.

## Rescan conditions

Extend `rescan` with transition-based conditions in addition to value conditions:

```lua
entries = entries:rescan({increased = true})
entries = entries:rescan({decreased = true})
entries = entries:rescan({unchanged = true})
entries = entries:rescan({changed = true})
```

These compare the current value against the value recorded at the last scan or rescan.
Entries need to carry their previous value for this to work.

## Watch and match

Both poll entries on an interval and evaluate a sequence of conditions against observed value
transitions. Identical consecutive samples are always skipped before evaluation.

`watch` resets an entry's sequence progress on a violation and returns all entries that
completed the full sequence at least once before the timeout.

`match` discards an entry on any violation and returns only entries that completed the full
sequence without interruption.

```lua
-- watch: noisy process, reset on violation
local entries = p:scan({type = "f32", in_range = {min = 200, max = 500}})
local timers = entries:watch({
    sequence = seqs.repeated(decrease).take(10),
    timeout = secs(12),
    interval = ms(50),
})

-- match: clean signal, discard on violation
local counters = entries:match({
    sequence = seqs.of({eq(10), eq(15), eq(10), eq(0)}),
    timeout = secs(5),
    interval = ms(50),
})
```

Both return an entry list. The returned entries can be used with `get`, `set`, `freeze`, `pin`.

## Sequences

Sequences are composable condition chains evaluated against value transitions.

```lua
-- all steps are predicates evaluated against the new value on each non-identical sample
seqs.of({eq(10), in_range(1, 5), decreased, eq(0)})

-- repeat a single condition n times
seqs.repeated(decrease).take(10)
seqs.repeated(eq(0)).take(3)

-- concatenate with ..
seqs.repeated(decrease).take(5) .. seqs.of({in_range(0, 10), eq(0)})
```

Available predicates: `eq(v)`, `in_range(min, max)`, `increased`, `decreased`, `unchanged`, `changed`.

Step semantics: a step advances when the new sample satisfies the predicate. A step is violated
when the new sample fails the predicate. Repeated identical samples are ignored before evaluation.

## freeze and pin

`freeze` locks an entry at its last observed value. `pin` locks it at an explicit value.
Both hold for the lifetime of the script by running a background task that rewrites the address
on each tick.

```lua
timers:freeze()
entries[1]:pin(9.0)
entries[1]:unpin()
```

## Time helpers

```lua
secs(12)   -- 12 seconds as milliseconds
ms(500)    -- 500 milliseconds
```

## Display utilities

A display helper for printing entry lists as a readable table in the terminal.
Likely a Lua-side helper, not Zig.

```lua
display(entries)
-- address          type   value
-- 0x7f1234560010   f32    8.3
-- 0x7f1234560048   f32    8.3
```

## LuaLS integration

The REPL currently has a static hardcoded completion list. Connecting it to LuaLS would give live context-aware completions inside the REPL, so typing `p:` actually shows the methods available on a process object rather than nothing.

The second part is stubs for editor support. Once the API is stable, generate `.d.lua` definition files so editors with LuaLS get autocompletion and type hints when writing MemScript scripts outside the REPL. The stubs live in a `types/` directory and are pointed at via `.luarc.json`.

## Filter improvements

Additional filter options for `proc.list` and `entries` that come up naturally during REPL exploration. Filtering by cmdline substring is useful when multiple processes share the same name. Re-filtering an existing entry list by address range or region pathname helps narrow down results after a broad scan without rescanning. Display helpers that print entry tables make these exploration loops faster.