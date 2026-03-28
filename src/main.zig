const std = @import("std");
const memscript = @import("memscript");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const context = memscript.Context.init(arena, init.io, &stdout_buffer, &stderr_buffer);

    if (args.len != 2) {
        try printUsage(context, args[0]);
        std.process.exit(1);
    }

    if (std.os.linux.getuid() != 0 and std.os.linux.geteuid() != 0) {
        try context.printStderr("memscript requires root privileges, run with sudo or doas\n", .{});
        std.process.exit(1);
    }

    const script_path = try arena.dupeZ(u8, args[1]);
    const state = try memscript.Lua.init();
    defer memscript.Lua.deinit(state);

    memscript.Lua.openLibs(state);
    memscript.Api.register(state);

    memscript.Lua.loadFile(state, .{ .path = script_path }) catch |err| {
        try printLuaFailure(context, state, "failed to load script", err);
        std.process.exit(1);
    };

    memscript.Lua.protectedCall(state, 0, memscript.Lua.mult_return, 0) catch |err| {
        try printLuaFailure(context, state, "script execution failed", err);
        std.process.exit(1);
    };
}

fn printUsage(context: memscript.Context, exe_name: []const u8) !void {
    try context.printStderr("usage: {s} <script.lua>\n", .{exe_name});
}

fn printLuaFailure(context: memscript.Context, state: *memscript.Lua.State, prefix: []const u8, err: anyerror) !void {
    if (memscript.Lua.toString(state, -1)) |message| {
        try context.printStderr("{s}: {s}\n", .{ prefix, message });
        return;
    }

    try context.printStderr("{s}: {s}\n", .{ prefix, @errorName(err) });
}
