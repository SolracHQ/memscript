const std = @import("std");
const Context = @import("context.zig");
const Linenoise = @import("linenoise.zig");
const Lua = @import("lua.zig");

const ChunkState = enum { incomplete, ready };

const prompt: [:0]const u8 = "mem> ";
const continuation_prompt: [:0]const u8 = "...> ";
const workspace_name: [:0]const u8 = "_MEMSCRIPT_REPL";

const completion_items = [_][:0]const u8{
    ".exit",
    ".help",
    ".quit",
    "mem.read_u32(",
    "mem.write_u32(",
    "proc.list(",
    "proc.list({ name = \"\" })",
};

/// Runs an interactive Lua REPL on an already initialized state.
///
/// The caller is responsible for opening Lua libraries and registering any
/// application-specific globals before entering the loop.
pub fn run(context: Context, state: *Lua.State) !void {
    initWorkspace(state);

    try context.printStdout("memscript Lua REPL\n", .{});
    try context.printStdout("type .quit or press Ctrl-D to exit\n", .{});
    try context.printStdout("top-level locals do not persist; use pid = 123, not local pid = 123\n", .{});

    Linenoise.setMultiLine(true);
    Linenoise.setCompletionCallback(completionCallback);

    while (true) {
        const source = (try readChunk(context, state)) orelse break;
        defer context.allocator.free(source);

        const trimmed = std.mem.trim(u8, source, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, ".quit") or std.mem.eql(u8, trimmed, ".exit")) {
            break;
        }

        if (try handleBuiltinCommand(context, trimmed)) continue;

        const history_entry = try context.allocator.dupeZ(u8, source);
        defer context.allocator.free(history_entry);
        _ = Linenoise.historyAdd(history_entry);

        try evalLine(context, state, source);
    }
}

fn checkChunk(state: *Lua.State, context: *const Context, source: []const u8) !ChunkState {
    const source_zero_terminated = try context.allocator.dupeZ(u8, source);
    defer context.allocator.free(source_zero_terminated);

    const stack_base = Lua.getTop(state);
    defer Lua.setTop(state, stack_base);

    Lua.loadString(state, source_zero_terminated) catch |err| switch (err) {
        error.Syntax => {
            const message = Lua.toString(state, -1) orelse "";
            if (std.mem.endsWith(u8, message, "<eof>")) {
                Lua.pop(state, 1);
                if (try canLoadAsExpression(state, context, source)) {
                    return .ready;
                }
                return .incomplete;
            }
        },
        else => {},
    };
    return .ready;
}

fn canLoadAsExpression(state: *Lua.State, context: *const Context, source: []const u8) !bool {
    const expression_source = try allocReturnSource(context.allocator, source);
    defer context.allocator.free(expression_source);

    Lua.loadString(state, expression_source) catch |err| switch (err) {
        error.Syntax => {
            Lua.pop(state, 1);
            return false;
        },
        else => return err,
    };

    Lua.pop(state, 1);
    return true;
}

fn readChunk(context: Context, state: *Lua.State) !?[]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(context.allocator);

    var current_prompt = prompt;
    while (true) {
        const line = Linenoise.readLine(current_prompt) orelse {
            if (source.items.len == 0) return null;
            const chunk = try source.toOwnedSlice(context.allocator);
            return chunk;
        };
        defer Linenoise.freeLine(line);

        if (source.items.len != 0) {
            try source.append(context.allocator, '\n');
        }
        try source.appendSlice(context.allocator, line);

        switch (try checkChunk(state, &context, source.items)) {
            .ready => {
                const chunk = try source.toOwnedSlice(context.allocator);
                return chunk;
            },
            .incomplete => current_prompt = continuation_prompt,
        }
    }
}

fn handleBuiltinCommand(context: Context, source: []const u8) !bool {
    if (std.mem.eql(u8, source, ".help")) {
        try printHelp(context);
        return true;
    }

    return false;
}

fn printHelp(context: Context) !void {
    try context.printStdout("REPL commands:\n", .{});
    try context.printStdout("  .help              Show this help\n", .{});
    try context.printStdout("  .quit, .exit       Exit the REPL\n", .{});
    try context.printStdout("Examples:\n", .{});
    try context.printStdout("  proc.list()\n", .{});
    try context.printStdout("  proc.list({{ name = \"target\" }})\n", .{});
    try context.printStdout("  mem.read_u32(pid, address)\n", .{});
    try context.printStdout("  mem.write_u32(pid, address, value)\n", .{});
    try context.printStdout("Multiline input stays open until Lua sees a complete chunk.\n", .{});
}

fn completionCallback(buffer: [*c]const u8, completions: ?*Linenoise.Completions) callconv(.c) void {
    const list = completions orelse return;
    const input = std.mem.span(buffer);
    const stem_start = completionStemStart(input);
    const stem = input[stem_start..];

    for (completion_items) |item| {
        if (!std.mem.startsWith(u8, item, stem)) continue;

        if (stem_start == 0) {
            Linenoise.addCompletion(list, item);
            continue;
        }

        var candidate_buffer: [4096]u8 = undefined;
        const candidate_len = stem_start + item.len;
        if (candidate_len >= candidate_buffer.len) continue;

        @memcpy(candidate_buffer[0..stem_start], input[0..stem_start]);
        @memcpy(candidate_buffer[stem_start..candidate_len], item);
        candidate_buffer[candidate_len] = 0;
        Linenoise.addCompletion(list, candidate_buffer[0..candidate_len :0]);
    }
}

fn completionStemStart(input: []const u8) usize {
    var index = input.len;
    while (index > 0) {
        const char = input[index - 1];
        if (!isCompletionStemChar(char)) break;
        index -= 1;
    }
    return index;
}

fn isCompletionStemChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.';
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

    Lua.protectedCall(state, 0, Lua.MULT_RETURN, 0) catch |err| {
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
    _ = Lua.setUpvalue(state, -2, 1);
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
        try context.printStdout("{s}", .{Lua.typeName(state, Lua.valueType(state, abs_index))});
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

test "completion stem starts at last token" {
    try std.testing.expectEqual(@as(usize, 0), completionStemStart("proc."));
    try std.testing.expectEqual(@as(usize, 8), completionStemStart("procs = proc."));
    try std.testing.expectEqual(@as(usize, 5), completionStemStart("call(proc.li"));
}
