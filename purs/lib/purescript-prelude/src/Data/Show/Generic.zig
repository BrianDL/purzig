//! FILE: purs/lib/purescript-prelude/src/Data/Show/Generic.zig
//!
//! FFI for Data.Show.Generic.
//!
//! `intercalate` is JavaScript's `Array.prototype.join`: the separator goes
//! BETWEEN elements, so an empty array is the empty string and a one-element
//! array is that element alone.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

fn intercalate(separator: Value, xs: Value) Value {
    const items = xs.asArray();
    const gpa = rt.alloc();

    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |x, i| {
        if (i > 0) out.appendSlice(gpa, separator.asString()) catch @panic("runtime: out of memory");
        out.appendSlice(gpa, x.asString()) catch @panic("runtime: out of memory");
    }
    return Value.mkString(out.items);
}

pub const @"ps.intercalate" = rt.curry(intercalate);
