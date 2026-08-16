//! FFI for Data.Array.NonEmpty.Internal.
//!
//! All three assume a non-empty array, which the `NonEmptyArray` newtype
//! guarantees -- there is no emptiness check in the originals and none here.
//!
//! `traverse1Impl` is the `Semigroup`-flavoured sibling of
//! `Data.Traversable.traverseArrayImpl`, but it is NOT the same algorithm:
//! `Apply` has no `pure`, so there is no empty case to bottom out at and the
//! balanced-tree split is unavailable. The original therefore folds from the
//! right, and wraps that fold in an explicit trampoline (`Cont`) purely to
//! keep JavaScript's stack out of it.
//!
//! The trampoline is dropped here. It encodes a right fold as a chain of
//! thunks the caller unwinds in a loop; a Zig `while` walking the array
//! backwards is the same computation with the same association order, and the
//! recursion it was avoiding does not exist in this version. The applicative
//! structure -- `apply(map(consList)(f(x)))(acc)` -- is preserved exactly,
//! which is the part that is observable.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

fn foldr1Impl(f: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    var acc = items[items.len - 1];

    var i = items.len - 1;
    while (i > 0) {
        i -= 1;
        acc = try rt.apply2(f, items[i], acc);
    }
    return acc;
}

fn foldl1Impl(f: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    var acc = items[0];
    for (items[1..]) |x| {
        acc = try rt.apply2(f, acc, x);
    }
    return acc;
}

// The cons list the traversal accumulates into, as data constructors. Never
// seen by PureScript: it is threaded through the functor and unwound below.
fn consCell(head: Value, tail: Value) Value {
    return Value.mkData("Cons", rt.copyValues(&.{ head, tail }));
}

fn finalCell(head: Value) Value {
    return Value.mkData("Cons", rt.copyValues(&.{ head, Value.mkData("Nil", &.{}) }));
}

fn listToArray(list: Value) Value {
    var out: std.ArrayList(Value) = .empty;
    var current = list;
    while (current.hasTag("Cons")) {
        out.append(rt.alloc(), current.arg(0)) catch @panic("runtime: out of memory");
        current = current.arg(1);
    }
    return Value.mkArray(out.items);
}

const cons_fn = rt.curry(consCell);
const final_fn = rt.curry(finalCell);
const to_array_fn = rt.curry(listToArray);

fn traverse1Impl(apply_fn: Value, map_fn: Value, f: Value, xs: Value) Error!Value {
    const items = xs.asArray();

    // Seed with the last element, then fold leftwards -- `buildFrom` in the
    // original.
    var acc = try rt.apply2(map_fn, final_fn, try rt.apply(f, items[items.len - 1]));

    var i = items.len - 1;
    while (i > 0) {
        i -= 1;
        const head = try rt.apply2(map_fn, cons_fn, try rt.apply(f, items[i]));
        acc = try rt.apply2(apply_fn, head, acc);
    }

    return try rt.apply2(map_fn, to_array_fn, acc);
}

pub const @"ps.foldr1Impl" = rt.curry(foldr1Impl);
pub const @"ps.foldl1Impl" = rt.curry(foldl1Impl);
pub const @"ps.traverse1Impl" = rt.curry(traverse1Impl);
