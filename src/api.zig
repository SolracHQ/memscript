const lua = @import("lua.zig");
const Context = @import("context.zig");
const shared = @import("api/shared.zig");
const mem_api = @import("api/mem.zig");
const proc_api = @import("api/proc.zig");

pub fn register(state: *lua.State, context: *const Context) void {
    shared.registerContext(state, context);
    mem_api.register(state);
    proc_api.register(state);
}
