//! The single boxed value type that all generated code traffics in.
//!
//! CoreFn is untyped, so v0 of the backend does no type-directed code
//! generation: every PureScript expression becomes a `Value`. Slow and
//! correct. Unboxing is a later pass.

const std = @import("std");

/// The one error a PureScript program can raise: `Effect.Exception.throw`.
///
/// Zig has no stack unwinding -- errors are values in the return type and every
/// call site decides explicitly what to do with them -- so a PureScript
/// exception has to be threaded through the return type of every function that
/// could be on the path to a `throw`. Since the backend is untyped, that is all
/// of them.
///
/// Zig error values carry no payload, so the thrown `Error` value itself
/// travels in a side channel: `rt.throwValue` stashes it and returns
/// `error.PsException`, and `rt.takeError` retrieves it in the handler. This is
/// the standard Zig pattern for errors that need diagnostics attached.
pub const Error = error{PsException};

/// A closure body. Takes its captured environment and exactly one argument.
///
/// CoreFn is fully curried -- every `Abs` binds one name, every `App` applies
/// one argument -- so one-argument closures need no arity analysis.
///
/// The environment is a flat slice, indexed positionally. Deliberately not a
/// generated struct per lambda: the emitter would then have to name and emit a
/// type for every `Abs`, and every call site would need @ptrCast/@alignCast.
/// One pointer indirection per capture is irrelevant at v0, and
/// purescript-backend-optimizer would erase most captures later anyway.
///
/// Fallible because any application may reach a `throw`. This is the single
/// declaration that forces generated code's signatures, so changing it and
/// changing the emitter are necessarily the same commit.
pub const Fn1 = *const fn (env: []const Value, arg: Value) Error!Value;

pub const Closure = struct {
    func: Fn1,
    env: []const Value,
};

/// A saturated data constructor, e.g. `Just 3` or `Cons x xs`.
pub const Data = struct {
    tag: []const u8,
    fields: []const Value,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// The empty environment, for closures that capture nothing.
pub const no_env: []const Value = &.{};

pub const Value = union(enum) {
    unit,
    boolean: bool,
    integer: i32,
    number: f64,
    string: []const u8,
    char: u21,
    array: []const Value,
    record: []const Field,
    data: Data,
    closure: Closure,

    /// A mutable cell, backing `Effect.Ref`. The only mutable thing in the
    /// runtime: every other variant is immutable, and `updateRecord` is
    /// explicitly copy-on-write.
    ///
    /// It has to be a pointer rather than an inline value. `Ref` semantics are
    /// that a write is observable through every copy of the reference, and
    /// `Value` is passed by value everywhere; only indirection gives that.
    /// `newWithSelf` additionally needs the cell to exist before its contents
    /// are computed, which a pointer allows and an inline value does not.
    ref: *Value,

    // ---- constructors -------------------------------------------------
    // Named `mk*` because a union cannot carry a declaration and a field
    // with the same identifier.

    pub fn mkUnit() Value {
        return .unit;
    }

    pub fn mkBool(v: bool) Value {
        return .{ .boolean = v };
    }

    pub fn mkInt(v: i32) Value {
        return .{ .integer = v };
    }

    pub fn mkNumber(v: f64) Value {
        return .{ .number = v };
    }

    pub fn mkString(v: []const u8) Value {
        return .{ .string = v };
    }

    pub fn mkChar(v: u21) Value {
        return .{ .char = v };
    }

    pub fn mkArray(items: []const Value) Value {
        return .{ .array = items };
    }

    pub fn mkRecord(fields: []const Field) Value {
        return .{ .record = fields };
    }

    pub fn mkData(tag: []const u8, fields: []const Value) Value {
        return .{ .data = .{ .tag = tag, .fields = fields } };
    }

    pub fn mkClosure(func: Fn1, env: []const Value) Value {
        return .{ .closure = .{ .func = func, .env = env } };
    }

    /// Wrap an already-allocated cell. `rt.newRef` is the usual way in; this
    /// exists for `newWithSelf`, which must publish the reference before it has
    /// a value to put in it.
    pub fn mkRef(cell: *Value) Value {
        return .{ .ref = cell };
    }

    // ---- accessors ----------------------------------------------------
    // Generated code is well-typed by construction (purs already checked it),
    // so a mismatch here is a backend bug. Panic loudly.

    pub fn asBool(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            else => @panic("runtime: expected Boolean"),
        };
    }

    pub fn asInt(self: Value) i32 {
        return switch (self) {
            .integer => |i| i,
            else => @panic("runtime: expected Int"),
        };
    }

    pub fn asNumber(self: Value) f64 {
        return switch (self) {
            .number => |n| n,
            else => @panic("runtime: expected Number"),
        };
    }

    pub fn asString(self: Value) []const u8 {
        return switch (self) {
            .string => |s| s,
            else => @panic("runtime: expected String"),
        };
    }

    pub fn asChar(self: Value) u21 {
        return switch (self) {
            .char => |c| c,
            else => @panic("runtime: expected Char"),
        };
    }

    pub fn asArray(self: Value) []const Value {
        return switch (self) {
            .array => |items| items,
            else => @panic("runtime: expected Array"),
        };
    }

    /// String equality, for `LiteralBinder` on String. On `Value` rather than
    /// emitted as `std.mem.eql` inline, because only the entry module imports
    /// std -- and generated code is meant to touch nothing but `rt`.
    pub fn stringEq(self: Value, other: []const u8) bool {
        return std.mem.eql(u8, self.asString(), other);
    }

    pub fn asRecord(self: Value) []const Field {
        return switch (self) {
            .record => |fields| fields,
            else => @panic("runtime: expected Record"),
        };
    }

    /// Record field access, for CoreFn `Accessor`.
    pub fn field(self: Value, name: []const u8) Value {
        for (self.asRecord()) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.value;
        }
        @panic("runtime: no such record field");
    }

    /// Constructor tag test, for CoreFn `ConstructorBinder`.
    pub fn hasTag(self: Value, tag: []const u8) bool {
        return switch (self) {
            .data => |d| std.mem.eql(u8, d.tag, tag),
            else => false,
        };
    }

    /// Positional field of a data constructor, for `ConstructorBinder` sub-binders.
    pub fn arg(self: Value, index: usize) Value {
        return switch (self) {
            .data => |d| d.fields[index],
            else => @panic("runtime: expected a data constructor"),
        };
    }

    /// The cell behind an `Effect.Ref`. Read through `.*`, write through
    /// `.* =`. Only `Effect/Ref.zig` should need this.
    pub fn asRef(self: Value) *Value {
        return switch (self) {
            .ref => |cell| cell,
            else => @panic("runtime: expected a Ref"),
        };
    }
};

test "constructors and accessors round-trip" {
    try std.testing.expectEqual(@as(i32, 42), Value.mkInt(42).asInt());
    try std.testing.expect(Value.mkBool(true).asBool());
    try std.testing.expectEqualStrings("hi", Value.mkString("hi").asString());
}

test "record field lookup" {
    const fields = [_]Field{
        .{ .name = "x", .value = Value.mkInt(1) },
        .{ .name = "y", .value = Value.mkInt(2) },
    };
    const rec = Value.mkRecord(&fields);
    try std.testing.expectEqual(@as(i32, 2), rec.field("y").asInt());
    try std.testing.expectEqual(@as(usize, 2), rec.asRecord().len);

    try std.testing.expect(Value.mkString("skip").stringEq("skip"));
    try std.testing.expect(!Value.mkString("skip").stringEq("skop"));

    const items = [_]Value{ Value.mkInt(7), Value.mkChar('q') };
    const arr = Value.mkArray(&items);
    try std.testing.expectEqual(@as(usize, 2), arr.asArray().len);
    try std.testing.expectEqual(@as(i32, 7), arr.asArray()[0].asInt());
    try std.testing.expectEqual(@as(u21, 'q'), arr.asArray()[1].asChar());
}

test "data constructor tag and fields" {
    const payload = [_]Value{Value.mkInt(3)};
    const just = Value.mkData("Just", &payload);
    try std.testing.expect(just.hasTag("Just"));
    try std.testing.expect(!just.hasTag("Nothing"));
    try std.testing.expectEqual(@as(i32, 3), just.arg(0).asInt());
}
