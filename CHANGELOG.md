# Changelog

## 0.0.1

First working prototype.

### Added

- Basic CLI entry point that loads and runs a Lua script
- Minimal Lua wrapper around the system Lua 5.4 headers
- Global Lua `mem` table with `read_u32(pid, address)` and `write_u32(pid, address, value)`
- Linux process memory access through `process_vm_readv` and `process_vm_writev`
- Working example using `example/target.c` and `example/example.lua`
- `justfile` for common build, run, test, and cleanup tasks
