//! Thin Lua 5.4 wrapper over the system C headers.
//!
//! This module intentionally stays close to the Lua C API. It shortens some
//! names, groups a few related constants into Zig enums, and adds only small
//! helpers where the raw C surface is awkward from Zig.
const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const State = c.lua_State;
pub const Number = c.lua_Number;
pub const Integer = c.lua_Integer;
pub const Unsigned = c.lua_Unsigned;
pub const KContext = c.lua_KContext;
pub const CFunction = c.lua_CFunction;
pub const KFunction = c.lua_KFunction;
pub const Reader = c.lua_Reader;
pub const Writer = c.lua_Writer;
pub const Alloc = c.lua_Alloc;
pub const WarnFunction = c.lua_WarnFunction;
pub const Debug = c.lua_Debug;
pub const Reg = c.luaL_Reg;
pub const Buffer = c.luaL_Buffer;

/// Errors surfaced by the small Zig helpers in this module.
///
/// They mirror the common Lua status codes used by `luaL_load*` and protected
/// calls.
pub const Error = error{
    OutOfMemory,
    Runtime,
    Syntax,
    MessageHandler,
    File,
    Unknown,
};

/// A null-terminated script path suitable for Lua's file loading API.
pub const Script = struct {
    path: [:0]const u8,
};

/// Lua call and execution status codes.
pub const Status = enum(c_int) {
    ok = c.LUA_OK,
    yield = c.LUA_YIELD,
    err_run = c.LUA_ERRRUN,
    err_syntax = c.LUA_ERRSYNTAX,
    err_mem = c.LUA_ERRMEM,
    err_err = c.LUA_ERRERR,
};

/// Value kinds returned by `typeOf` and related Lua C API calls.
pub const Type = enum(c_int) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    light_userdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
};

/// Comparison operators accepted by `lua_compare`.
pub const CompareOp = enum(c_int) {
    eq = c.LUA_OPEQ,
    lt = c.LUA_OPLT,
    le = c.LUA_OPLE,
};

/// Arithmetic and bitwise operators accepted by `lua_arith`.
pub const ArithOp = enum(c_int) {
    add = c.LUA_OPADD,
    sub = c.LUA_OPSUB,
    mul = c.LUA_OPMUL,
    mod = c.LUA_OPMOD,
    pow = c.LUA_OPPOW,
    div = c.LUA_OPDIV,
    idiv = c.LUA_OPIDIV,
    band = c.LUA_OPBAND,
    bor = c.LUA_OPBOR,
    bxor = c.LUA_OPBXOR,
    shl = c.LUA_OPSHL,
    shr = c.LUA_OPSHR,
    unm = c.LUA_OPUNM,
    bnot = c.LUA_OPBNOT,
};

pub const mult_return = c.LUA_MULTRET;
pub const registry_index = c.LUA_REGISTRYINDEX;
pub const ridx_mainthread = c.LUA_RIDX_MAINTHREAD;
pub const ridx_globals = c.LUA_RIDX_GLOBALS;
pub const min_stack = c.LUA_MINSTACK;

pub const absIndex = c.lua_absindex;
pub const getTop = c.lua_gettop;
pub const setTop = c.lua_settop;
pub const pushValue = c.lua_pushvalue;
pub const checkStack = c.lua_checkstack;
pub const isNumber = c.lua_isnumber;
pub const isString = c.lua_isstring;
pub const isInteger = c.lua_isinteger;
pub const toBoolean = c.lua_toboolean;
pub const pushNil = c.lua_pushnil;
pub const pushNumber = c.lua_pushnumber;
pub const pushInteger = c.lua_pushinteger;
pub const pushBoolean = c.lua_pushboolean;
pub const pushLightUserdata = c.lua_pushlightuserdata;
pub const getGlobal = c.lua_getglobal;
pub const setGlobal = c.lua_setglobal;
pub const getField = c.lua_getfield;
pub const setField = c.lua_setfield;
pub const createTable = c.lua_createtable;
pub const rawLen = c.lua_rawlen;
pub const compare = c.lua_compare;
pub const arith = c.lua_arith;
pub const openLibs = c.luaL_openlibs;
pub const checkInteger = c.luaL_checkinteger;
pub const checkNumber = c.luaL_checknumber;
pub const checkString = c.luaL_checkstring;

/// Creates a fresh Lua state.
///
/// The returned state must later be closed with `deinit`.
pub fn init() Error!*State {
    return c.luaL_newstate() orelse Error.OutOfMemory;
}

/// Closes a Lua state previously created with `init`.
pub fn deinit(state: *State) void {
    c.lua_close(state);
}

/// Loads a script file and leaves the compiled chunk on the stack.
///
/// This does not execute the file. Call `protectedCall` or `call` afterwards.
pub fn loadFile(state: *State, script: Script) Error!void {
    return statusToError(c.luaL_loadfilex(state, script.path.ptr, null));
}

/// Loads a Lua chunk from a string and leaves the compiled chunk on the stack.
pub fn loadString(state: *State, source: [:0]const u8) Error!void {
    return statusToError(c.luaL_loadstring(state, source.ptr));
}

/// Calls the function currently on the Lua stack.
///
/// This is the direct, unprotected call path and follows the C API semantics.
pub fn call(state: *State, nargs: c_int, nresults: c_int) void {
    c.lua_callk(state, nargs, nresults, 0, null);
}

/// Protected-call primitive returning the raw Lua status code.
pub fn pcall(state: *State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return c.lua_pcallk(state, nargs, nresults, errfunc, 0, null);
}

/// Protected call that maps Lua status codes into Zig errors.
pub fn protectedCall(state: *State, nargs: c_int, nresults: c_int, errfunc: c_int) Error!void {
    return statusToError(pcall(state, nargs, nresults, errfunc));
}

/// Pops `n` values from the top of the Lua stack.
pub fn pop(state: *State, n: c_int) void {
    c.lua_settop(state, -n - 1);
}

/// Pushes a new empty table onto the stack.
pub fn newTable(state: *State) void {
    c.lua_createtable(state, 0, 0);
}

/// Pushes a C function with no upvalues onto the stack.
pub fn pushFunction(state: *State, function: CFunction) void {
    c.lua_pushcclosure(state, function, 0);
}

/// Converts a stack value to a Lua integer, returning `null` on conversion failure.
pub fn toInteger(state: *State, index: c_int) ?Integer {
    var is_num: c_int = 0;
    const value = c.lua_tointegerx(state, index, &is_num);
    if (is_num == 0) return null;
    return value;
}

/// Converts a stack value to a Lua number, returning `null` on conversion failure.
pub fn toNumber(state: *State, index: c_int) ?Number {
    var is_num: c_int = 0;
    const value = c.lua_tonumberx(state, index, &is_num);
    if (is_num == 0) return null;
    return value;
}

/// Returns a borrowed Lua string slice for the value at `index`.
///
/// The returned memory is owned by Lua and must not outlive the underlying Lua
/// value or state.
pub fn toString(state: *State, index: c_int) ?[:0]const u8 {
    var len: usize = 0;
    const ptr = c.lua_tolstring(state, index, &len) orelse return null;
    return ptr[0..len :0];
}

/// Returns the Lua value kind at `index`.
pub fn typeOf(state: *State, index: c_int) Type {
    return @enumFromInt(c.lua_type(state, index));
}

/// Returns Lua's human-readable name for a value kind.
pub fn typeName(state: *State, lua_type: Type) [:0]const u8 {
    return std.mem.span(c.lua_typename(state, @intFromEnum(lua_type)));
}

fn statusToError(status: c_int) Error!void {
    return switch (status) {
        c.LUA_OK => {},
        c.LUA_ERRRUN => Error.Runtime,
        c.LUA_ERRSYNTAX => Error.Syntax,
        c.LUA_ERRMEM => Error.OutOfMemory,
        c.LUA_ERRERR => Error.MessageHandler,
        c.LUA_ERRFILE => Error.File,
        else => Error.Unknown,
    };
}

test "lua skeleton compiles" {
    try std.testing.expect(@TypeOf(c.luaL_newstate) != void);
    try std.testing.expect(@intFromEnum(Type.number) == c.LUA_TNUMBER);
}
