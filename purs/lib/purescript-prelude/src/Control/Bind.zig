//! FFI for Control.Bind.
//!
//! Unlike map and apply, the result length is not known in advance, so this
//! collects into a growable list before freezing it into an array. The list
//! allocates from the same arena as everything else.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

/// Fallible: `f` is arbitrary PureScript code.
fn arrayBind(xs: Value, f: Value) rt.Error!Value {
    const items = xs.asArray();

    var out: std.ArrayList(Value) = .empty;
    for (items) |x| {
        const produced = (try rt.apply(f, x)).asArray();
        out.appendSlice(rt.alloc(), produced) catch @panic("runtime: out of memory");
    }
    return Value.mkArray(out.items);
}

pub const @"ps.arrayBind" = rt.curry(arrayBind);
