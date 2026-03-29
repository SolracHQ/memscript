# MemScript

MemScript is a scriptable process memory inspector and editor, driven by Lua.
A hobby project to learn Zig and Lua, and mess with game memory along the way.

If you just want to see what it can do, skip to [Usage](#usage).
For what is coming next, see [planning.md](planning.md).

## Motivation

I grew up using Cheat Engine on Windows and Game Conqueror on Linux. I always wanted to build something like it myself. This is the first attempt that made it past the prototype stage, and the language choices are why.

For the host language I had a specific set of requirements: full control over memory layout and allocation, no exceptions or hidden control flow, generics and a useful stdlib, and a build system that does not make linking third-party code a project of its own. Zig hits all of them. I also just wanted to take a closer look at the language, and this was a good excuse.

For the scripting layer I ruled out a UI early, partly because I wanted something different from existing tools and partly because I am not good at making them. A scripting language gives the user more power, and the first user is me, so I thought about what I would actually want. I chose Lua not because it is my favorite language (1-indexed arrays and `end` delimiters are not for me) but because it meets the requirements that actually matter for an embedded scripting language: genuinely easy to embed in a host program, lightweight, and supported by real tooling. LuaLS in particular is what puts it ahead of the many small embeddable languages that are only known by their creators.

## Status

- `memscript <script.lua>` boots Lua, registers globals, loads the script, and runs it.
- `memscript` with no arguments starts an interactive REPL with history and tab completion.
- `proc.list()` enumerates live processes with optional name filtering.
- `process:scan()` scans all readable memory regions and returns matched entries.
- `entries:rescan()` narrows a previous result with a new condition.
- Individual entries support `get()` and `set()`.

## Usage

Run a script:

```sh
just run ./example/example.lua
```

Start the REPL:

```sh
just repl
```

In the REPL, top-level locals do not persist between lines. Use bare assignment instead:

```lua
-- this works across lines
p = proc.list({name = "target"})[1]

-- this does not
local p = proc.list({name = "target"})[1]
```

## API

```lua
-- list processes, optionally filtered by name substring
local p = proc.list({name = "target"})[1]

-- scan the whole process
local entries = p:scan({type = "f32", eq = 8.3})
local entries = p:scan({type = "u32", in_range = {min = 0, max = 255}})

-- narrow down results
entries = entries:rescan({eq = 9.0})
entries = entries:rescan({in_range = {min = 1.0, max = 10.0}})

-- read and write individual entries
print(entries[1]:get())
entries[1]:set(9.0)
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