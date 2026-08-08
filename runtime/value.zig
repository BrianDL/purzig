//! The single boxed value type that all generated code traffics in.
//!
//! CoreFn is untyped, so v0 of the backend does no type-directed code
//! generation: every PureScript expression becomes a `Value`. Slow and
//! correct. Unboxing is a later pass.

const std = @import("std");

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
pub const Fn1 = *const fn (env: []const Value, arg: Value) Value;

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

    /// Record field access, for CoreFn `Accessor`.
    pub fn field(self: Value, name: []const u8) Value {
        switch (self) {
            .record => |fields| {
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) return f.value;
                }
                @panic("runtime: no such record field");
            },
            else => @panic("runtime: expected Record"),
        }
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
}

test "data constructor tag and fields" {
    const payload = [_]Value{Value.mkInt(3)};
    const just = Value.mkData("Just", &payload);
    try std.testing.expect(just.hasTag("Just"));
    try std.testing.expect(!just.hasTag("Nothing"));
    try std.testing.expectEqual(@as(i32, 3), just.arg(0).asInt());
}
