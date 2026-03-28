const std = @import("std");
const memscript = @import("memscript");

const Lua = memscript.Lua;
const Api = memscript.Api;
const Repl = memscript.Repl;
const Context = memscript.Context;

pub fn main(init: std.process.Init) !void {
    const gpa: std.mem.Allocator = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    const context = Context.init(gpa, init.io, &stdout_buffer, &stderr_buffer);

    if (args.len > 2) {
        try printUsage(context, args[0]);
        std.process.exit(1);
    }

    if (std.os.linux.getuid() != 0 and std.os.linux.geteuid() != 0) {
        try context.printStderr("memscript requires root privileges, run with sudo or doas\n", .{});
        std.process.exit(1);
    }

    const state = try Lua.init();
    defer Lua.deinit(state);

    Lua.openLibs(state);
    Api.register(state, &context);

    if (args.len == 1) {
        try Repl.run(context, state);
        return;
    }

    const script_path = try gpa.dupeZ(u8, args[1]);

    Lua.loadFile(state, .{ .path = script_path }) catch |err| {
        try printLuaFailure(context, state, "failed to load script", err);
        std.process.exit(1);
    };

    Lua.protectedCall(state, 0, Lua.MULT_RETURN, 0) catch |err| {
        try printLuaFailure(context, state, "script execution failed", err);
        std.process.exit(1);
    };
}

fn printUsage(context: Context, exe_name: []const u8) !void {
    try context.printStderr("usage: {s} [script.lua]\n", .{exe_name});
}

fn printLuaFailure(context: Context, state: *Lua.State, prefix: []const u8, err: anyerror) !void {
    if (Lua.toString(state, -1)) |message| {
        try context.printStderr("{s}: {s}\n", .{ prefix, message });
        return;
    }

    try context.printStderr("{s}: {s}\n", .{ prefix, @errorName(err) });
}
