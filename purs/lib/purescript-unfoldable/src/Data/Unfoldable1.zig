//! FFI for Data.Unfoldable1.
//!
//! The same shape as `Data.Unfoldable`'s, with the test moved to the end: an
//! `Unfoldable1` always produces at least one element, so `f` is applied first
//! and the `Maybe` decides whether to continue rather than whether to start.
//! Note `snd` yields the `Maybe` here, where in `unfoldrArrayImpl` it yields
//! the next seed.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

fn unfoldr1ArrayImpl(
    isNothing: Value,
    fromJust: Value,
    fst: Value,
    snd: Value,
    f: Value,
    seed: Value,
) rt.Error!Value {
    var out: std.ArrayList(Value) = .empty;
    const gpa = rt.alloc();

    var current = seed;
    while (true) {
        const tuple = try rt.apply(f, current);
        out.append(gpa, try rt.apply(fst, tuple)) catch @panic("runtime: out of memory");

        const step = try rt.apply(snd, tuple);
        if ((try rt.apply(isNothing, step)).asBool()) return Value.mkArray(out.items);
        current = try rt.apply(fromJust, step);
    }
}

pub const @"ps.unfoldr1ArrayImpl" = rt.curry(unfoldr1ArrayImpl);
