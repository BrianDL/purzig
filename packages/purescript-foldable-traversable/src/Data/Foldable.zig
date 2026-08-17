//! FFI for Data.Foldable.
//!
//! Both of these exist only because folding an array through the generic
//! `Foldable` machinery would build a `Monoid` chain; the originals are plain
//! loops and so are these.
//!
//! Note the argument order differs between them -- `foldr` applies `f x acc`
//! and `foldl` applies `f acc x` -- which is the usual source of a silently
//! wrong fold, so each is spelled out rather than shared.

const rt = @import("runtime");
const Value = rt.Value;

fn foldrArray(f: Value, initial: Value, xs: Value) rt.Error!Value {
    const items = xs.asArray();
    var acc = initial;

    var i = items.len;
    while (i > 0) {
        i -= 1;
        acc = try rt.apply2(f, items[i], acc);
    }
    return acc;
}

fn foldlArray(f: Value, initial: Value, xs: Value) rt.Error!Value {
    var acc = initial;
    for (xs.asArray()) |x| {
        acc = try rt.apply2(f, acc, x);
    }
    return acc;
}

pub const @"ps.foldrArray" = rt.curry(foldrArray);
pub const @"ps.foldlArray" = rt.curry(foldlArray);
