# MemScript

MemScript is a scriptable process memory inspector and editor, driven by Lua.
A hobby project to learn Zig and Lua, and mess with game memory along the way.

## Status

The first end-to-end prototype works.

- `memscript <script.lua>` boots Lua, registers a global `mem` table, loads the script, and runs it.
- `mem.read_u32(pid, address)` and `mem.write_u32(pid, address, value)` work against a live Linux process.
- `proc.list()` returns live process entries, with optional name filtering.
- The example target in `example/target.c` can be modified from `example/example.lua`.

## Goals

- [x] Add a REPL, backed by Linenoise
- [x] Parse `/proc/<pid>/maps` and expose memory regions
- [x] Add `proc.list()` and process/region objects with methods (see API below)
- [ ] Add memory scanning and rescanning across regions
- [ ] Add pinning: hold a memory value at a fixed value for the lifetime of the script

## API

```lua
-- list processes, optionally filtered by name substring
local procs = proc.list({name = "target"})
local p = procs[1]

-- list memory regions, optionally filtered by permissions
local regions = p:regions({perms = "rw"})

-- scan a single region or the whole process
local entries = regions[1]:scan({type = "float", eq = 8.3})
local entries = p:scan({type = "float", eq = 8.3})

-- narrow down results
entries = entries:rescan({in_range = {min = 1.0, max = 10.0}})

-- read, write, or pin an entry
print(entries[1]:get())
entries[1]:set(9.0)
entries[1]:pin(9.0, {interval_ms = 100})
entries[1]:unpin()
```

## Example

Build and run the example target in one terminal:

```sh
zig cc example/target.c -o example/target.o
./example/target.o
```

Then run MemScript as root in another terminal:

```sh
just run ./example/example.lua
```

## License

MIT, see [LICENSE](LICENSE).