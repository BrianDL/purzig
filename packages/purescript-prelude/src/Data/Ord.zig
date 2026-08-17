//! FFI for Data.Ord.
//!
//! The scalar comparisons do NOT return -1/0/1. They take the `LT`, `EQ` and
//! `GT` constructors as their first three arguments and return one of them --
//! arity five in total. That is how the JavaScript implementation avoids
//! knowing anything about the Ordering type, and all five scalar variants
//! share one body there for the same reason they share one here.
//!
//! `ordArrayImpl` is the exception: it works in Ints, because the PureScript
//! side wraps it with conversions on both ends.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

const Ordering = enum { lt, eq, gt };

fn compareValues(x: Value, y: Value) Ordering {
    return switch (x) {
        .boolean => |a| order(@intFromBool(a), @intFromBool(y.asBool())),
        .integer => |a| order(a, y.asInt()),
        .number => |a| order(a, y.asNumber()),
        .char => |a| order(a, y.asChar()),
        .string => |a| switch (std.mem.order(u8, a, y.asString())) {
            .lt => .lt,
            .eq => .eq,
            .gt => .gt,
        },
        else => @panic("runtime: Ord applied to a non-scalar Value"),
    };
}

fn order(a: anytype, b: @TypeOf(a)) Ordering {
    if (a < b) return .lt;
    if (a == b) return .eq;
    return .gt;
}

fn unsafeCompareImpl(lt: Value, eq: Value, gt: Value, x: Value, y: Value) Value {
    return switch (compareValues(x, y)) {
        .lt => lt,
        .eq => eq,
        .gt => gt,
    };
}

/// Note the asymmetry, which is deliberate in the original: a LONGER left
/// array compares as -1.
///
/// Fallible because `f` is the element comparison, i.e. arbitrary PureScript
/// code that may `throw`. `rt.curry` coerces a plain `Value` return to
/// `Error!Value`, so only the functions that actually apply something need to
/// say so -- and this is one.
fn ordArrayImpl(f: Value, xs: Value, ys: Value) rt.Error!Value {
    const a = xs.asArray();
    const b = ys.asArray();

    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const o = (try rt.apply2(f, a[i], b[i])).asInt();
        if (o != 0) return Value.mkInt(o);
    }

    if (a.len == b.len) return Value.mkInt(0);
    return Value.mkInt(if (a.len > b.len) -1 else 1);
}

pub const @"ps.ordBooleanImpl" = rt.curry(unsafeCompareImpl);
pub const @"ps.ordIntImpl" = rt.curry(unsafeCompareImpl);
pub const @"ps.ordNumberImpl" = rt.curry(unsafeCompareImpl);
pub const @"ps.ordStringImpl" = rt.curry(unsafeCompareImpl);
pub const @"ps.ordCharImpl" = rt.curry(unsafeCompareImpl);
pub const @"ps.ordArrayImpl" = rt.curry(ordArrayImpl);
