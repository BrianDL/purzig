//! FFI for Data.Unfoldable.
//!
//! Six arguments, four of which are there so the FFI never learns how `Maybe`
//! or `Tuple` are represented: `isNothing`, `fromJust`, `fst` and `snd` all
//! arrive from the PureScript side. That is the same discipline as
//! `Data.Ord`'s scalar comparisons taking `LT`/`EQ`/`GT`.
//!
//! The result length is not known in advance, so this collects into a growable
//! list backed by the arena, exactly as `Control.Bind`'s `arrayBind` does.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

fn unfoldrArrayImpl(
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
        const step = try rt.apply(f, current);
        if ((try rt.apply(isNothing, step)).asBool()) return Value.mkArray(out.items);

        const tuple = try rt.apply(fromJust, step);
        out.append(gpa, try rt.apply(fst, tuple)) catch @panic("runtime: out of memory");
        current = try rt.apply(snd, tuple);
    }
}

pub const @"ps.unfoldrArrayImpl" = rt.curry(unfoldrArrayImpl);
