# MemScript

MemScript is a scriptable process memory inspector and editor, driven by Lua.
A hobby project to learn Zig and Lua, and mess with game memory along the way.

## Status

The first end-to-end prototype works.

- `memscript <script.lua>` boots Lua, registers a global `mem` table, loads the script, and runs it.
- `mem.read_u32(pid, address)` and `mem.write_u32(pid, address, value)` work against a live Linux process.
- The example target in `example/target.c` can be modified from `example/example.lua`.

## Goals

- [ ] Parse `/proc/<pid>/maps` and expose memory regions cleanly
- [ ] Add exploratory tools such as `list_processes()` and `list_mem_regions(pid)`
- [ ] Add memory scanning across all readable regions or a selected region
- [ ] Add a REPL, likely backed by Linenoise or a similar line-editing library
- [ ] Revisit the Lua surface before it hardens: current `read_u32`/`write_u32`, typed `read(type, pid, address)`, or table-driven calls are all still on the table

## Planned API

```lua
local pid = 1234
local address = 0x12345678

local value = mem.read_u32(pid, address)
print("value: " .. value)

mem.write_u32(pid, address, 42)
print("Value at address after write: " .. mem.read_u32(pid, address))
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