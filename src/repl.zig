const std = @import("std");
const Context = @import("context.zig");
const Linenoise = @import("linenoise.zig");
const Lua = @import("lua.zig");

const prompt: [:0]const u8 = "memscript> ";
const workspace_name: [:0]const u8 = "_MEMSCRIPT_REPL";

/// Runs an interactive Lua REPL on an already initialized state.
///
/// The caller is responsible for opening Lua libraries and registering any
/// application-specific globals before entering the loop.
pub fn run(context: Context, state: *Lua.State) !void {
    initWorkspace(state);

    try context.printStdout("memscript Lua REPL\n", .{});
    try context.printStdout("type .quit or press Ctrl-D to exit\n", .{});
    try context.printStdout("top-level locals do not persist; use pid = 123, not local pid = 123\n", .{});

    while (true) {
        const line = Linenoise.readLine(prompt) orelse break;
        defer Linenoise.freeLine(line);

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, ".quit") or std.mem.eql(u8, trimmed, ".exit")) {
            break;
        }

        _ = Linenoise.historyAdd(line);
        try evalLine(context, state, trimmed);
    }
}

fn evalLine(context: Context, state: *Lua.State, source: []const u8) !void {
    const stack_base = Lua.getTop(state);
    defer Lua.setTop(state, stack_base);

    const expression_source = try allocReturnSource(context.allocator, source);
    defer context.allocator.free(expression_source);

    const loaded_expression = try loadExpression(state, expression_source);
    if (!loaded_expression) {
        const statement_source = try context.allocator.dupeZ(u8, source);
        defer context.allocator.free(statement_source);

        Lua.loadString(state, statement_source) catch |err| {
            try printLuaFailure(context, state, "compile error", err);
            return;
        };

        bindWorkspace(state);
    }

    Lua.protectedCall(state, 0, Lua.mult_return, 0) catch |err| {
        try printLuaFailure(context, state, "runtime error", err);
        return;
    };

    try printResults(context, state, stack_base);
}

fn initWorkspace(state: *Lua.State) void {
    const stack_base = Lua.getTop(state);
    defer Lua.setTop(state, stack_base);

    Lua.newTable(state);
    Lua.newTable(state);
    _ = Lua.getGlobal(state, "_G");
    Lua.setField(state, -2, "__index");
    _ = Lua.setMetatable(state, -2);
    Lua.setGlobal(state, workspace_name);
}

fn bindWorkspace(state: *Lua.State) void {
    _ = Lua.getGlobal(state, workspace_name);
    _ = Lua.setupValue(state, -2, 1);
}

fn allocReturnSource(allocator: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const prefix = "return ";
    const buffer = try allocator.alloc(u8, prefix.len + source.len + 1);
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + source.len], source);
    buffer[buffer.len - 1] = 0;
    return buffer[0 .. buffer.len - 1 :0];
}

fn loadExpression(state: *Lua.State, source: [:0]const u8) Lua.Error!bool {
    Lua.loadString(state, source) catch |err| switch (err) {
        error.Syntax => {
            Lua.pop(state, 1);
            return false;
        },
        else => return err,
    };

    bindWorkspace(state);

    return true;
}

fn printResults(context: Context, state: *Lua.State, stack_base: c_int) !void {
    const top = Lua.getTop(state);
    if (top == stack_base) return;

    var index = stack_base + 1;
    while (index <= top) : (index += 1) {
        if (index > stack_base + 1) {
            try context.printStdout("\t", .{});
        }

        try printValue(context, state, index);
    }

    try context.printStdout("\n", .{});
}

fn printValue(context: Context, state: *Lua.State, index: c_int) !void {
    const abs_index = Lua.absIndex(state, index);
    const value = Lua.toDisplayString(state, abs_index) orelse {
        try context.printStdout("{s}", .{Lua.typeName(state, Lua.typeOf(state, abs_index))});
        return;
    };
    defer Lua.pop(state, 1);

    try context.printStdout("{s}", .{value});
}

fn printLuaFailure(context: Context, state: *Lua.State, prefix: []const u8, err: anyerror) !void {
    if (Lua.toString(state, -1)) |message| {
        try context.printStderr("{s}: {s}\n", .{ prefix, message });
        return;
    }

    try context.printStderr("{s}: {s}\n", .{ prefix, @errorName(err) });
}

test "repl module compiles" {
    try std.testing.expect(@TypeOf(run) != void);
}
