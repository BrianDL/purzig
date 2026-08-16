//! FFI for Data.Array.ST.
//!
//! An `STArray` is the runtime's `marray` variant: a pointer to a
//! `std.ArrayList(Value)` in the arena. This is the only file that mutates one.
//!
//! ## Every export is `rt.effect`, not `rt.curry`
//!
//! All but `new` are typed `STFnN`, and it is tempting to read that as
//! "performs on saturation, so `rt.curry`". It is the wrong reading. The
//! optimizer inlines `runSTFnN` into an `UncurriedEffectApp`, which the emitter
//! lowers to applications followed by `rt.runEffect`:
//!
//!     (try rt.runEffect((try rt.apply(unsafeThawImpl, xs))))
//!
//! So a saturated `STFnN` must yield a THUNK for `runEffect` to force, not the
//! finished value. `rt.effect` adds exactly that trailing unit thunk;
//! `rt.curry` would run the operation one step early and hand `runEffect` an
//! `STArray` to apply, which panics with "applied a non-function".
//!
//! This is the same convention `Control.Monad.ST.Internal`'s primitives already
//! use, and the reason is general: a foreign import that PERFORMS an effect
//! defers with `rt.effect`. Only a pure function of an ST value -- `ST.run` --
//! takes `rt.curry`.
//!
//! ## freeze/thaw and their unsafe counterparts
//!
//! In JavaScript an array and a mutable array are the same object, so
//! `unsafeFreeze` and `unsafeThaw` are the identity function. Here they are
//! different `Value` variants and something has to happen:
//!
//!   * `unsafeFreeze` hands the list's backing slice straight to `mkArray`, so
//!     it stays O(1) and allocation-free. This is the hot one -- `Data.Array`
//!     ends almost every ST block with it.
//!   * `unsafeThaw` COPIES, making it identical to `thaw`. Sharing would mean
//!     `@constCast`ing a slice that may point at static memory (an empty or
//!     literal array), and a subsequent `poke` would then write to a read-only
//!     page. The contract says the original must not be used again, so copying
//!     is invisible to any correct program and merely costs what `thaw` costs.
//!     `Data.Array` calls it exactly once, on a freshly built singleton.
//!
//! ## Return values
//!
//! Several of these return something JavaScript produced incidentally --
//! `push` returns the new length because `Array.prototype.push` does, `poke`
//! returns whether the index was in range. Those are in the PureScript types,
//! so they are reproduced rather than replaced with unit.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

fn gpa() std.mem.Allocator {
    return rt.alloc();
}

fn oom() noreturn {
    @panic("runtime: out of memory");
}

// -- creation, freezing, thawing ---------------------------------------------

fn newSTArray() Value {
    return rt.newMutArray(&.{});
}

/// O(1): the frozen array shares the list's storage. Safe under the function's
/// contract, which is that the `STArray` is not used afterwards.
fn unsafeFreezeImpl(xs: Value) Value {
    return Value.mkArray(xs.asMutArray().items);
}

/// Copies, unlike the JavaScript. See the header.
fn unsafeThawImpl(xs: Value) Value {
    return rt.newMutArray(xs.asArray());
}

fn freezeImpl(xs: Value) Value {
    const items = xs.asMutArray().items;
    return Value.mkArray(gpa().dupe(Value, items) catch oom());
}

fn thawImpl(xs: Value) Value {
    return rt.newMutArray(xs.asArray());
}

fn cloneImpl(xs: Value) Value {
    return rt.newMutArray(xs.asMutArray().items);
}

// -- reading -----------------------------------------------------------------

fn lengthImpl(xs: Value) Value {
    return Value.mkInt(@intCast(xs.asMutArray().items.len));
}

fn peekImpl(just: Value, nothing: Value, index: Value, xs: Value) Error!Value {
    const items = xs.asMutArray().items;
    const i = index.asInt();
    if (i < 0 or i >= items.len) return nothing;
    return try rt.apply(just, items[@intCast(i)]);
}

/// Returns whether the index was in range; an out-of-range poke is a no-op
/// rather than an error.
fn pokeImpl(index: Value, a: Value, xs: Value) Value {
    const items = xs.asMutArray().items;
    const i = index.asInt();
    if (i < 0 or i >= items.len) return Value.mkBool(false);
    items[@intCast(i)] = a;
    return Value.mkBool(true);
}

// -- growing and shrinking ---------------------------------------------------

fn pushImpl(a: Value, xs: Value) Value {
    const list = xs.asMutArray();
    list.append(gpa(), a) catch oom();
    return Value.mkInt(@intCast(list.items.len));
}

fn pushAllImpl(as: Value, xs: Value) Value {
    const list = xs.asMutArray();
    list.appendSlice(gpa(), as.asArray()) catch oom();
    return Value.mkInt(@intCast(list.items.len));
}

fn unshiftAllImpl(as: Value, xs: Value) Value {
    const list = xs.asMutArray();
    list.insertSlice(gpa(), 0, as.asArray()) catch oom();
    return Value.mkInt(@intCast(list.items.len));
}

fn popImpl(just: Value, nothing: Value, xs: Value) Error!Value {
    const list = xs.asMutArray();
    if (list.items.len == 0) return nothing;
    return try rt.apply(just, list.pop().?);
}

fn shiftImpl(just: Value, nothing: Value, xs: Value) Error!Value {
    const list = xs.asMutArray();
    if (list.items.len == 0) return nothing;
    return try rt.apply(just, list.orderedRemove(0));
}

/// `xs.splice(i, howMany, ...bs)`: remove `howMany` from `i`, insert `bs`
/// there, and return what was removed. The index is clamped the way
/// `Array.prototype.splice` clamps it -- a negative index counts from the end,
/// and both it and the count are pinned inside the array.
fn spliceImpl(index: Value, how_many: Value, bs: Value, xs: Value) Value {
    const list = xs.asMutArray();
    const len: i64 = @intCast(list.items.len);

    var start: i64 = index.asInt();
    if (start < 0) start += len;
    start = @max(0, @min(start, len));

    const count = @max(0, @min(@as(i64, how_many.asInt()), len - start));
    const from: usize = @intCast(start);
    const removed_len: usize = @intCast(count);

    const removed = gpa().dupe(Value, list.items[from .. from + removed_len]) catch oom();
    list.replaceRange(gpa(), from, removed_len, bs.asArray()) catch oom();
    return Value.mkArray(removed);
}

// -- sorting -----------------------------------------------------------------

/// A bottom-up merge sort over a scratch copy, transcribed from the original
/// rather than delegated to `std.sort`.
///
/// Two reasons not to delegate. It must be STABLE, which `std.sort.pdq` is not,
/// and `sortBy` is what `Data.Array.sort` and `sortWith` are built from, where
/// stability is part of the documented contract. And the comparison is
/// PureScript code that may throw, so it has to be threaded through an error
/// union -- which `std.sort`'s comparator signature does not allow.
///
/// `fromOrdering` turns the `Ordering` the comparator returns into an Int, so
/// this never learns how `Ordering` is represented.
fn mergeFromTo(
    compare: Value,
    from_ordering: Value,
    target: []Value,
    source: []Value,
    from: usize,
    to: usize,
) Error!void {
    const mid = from + ((to - from) >> 1);
    if (mid - from > 1) try mergeFromTo(compare, from_ordering, source, target, from, mid);
    if (to - mid > 1) try mergeFromTo(compare, from_ordering, source, target, mid, to);

    var i = from;
    var j = mid;
    var k = from;
    while (i < mid and j < to) {
        const x = source[i];
        const y = source[j];
        const c = (try rt.apply(from_ordering, try rt.apply2(compare, x, y))).asInt();
        if (c > 0) {
            target[k] = y;
            k += 1;
            j += 1;
        } else {
            // Not `>=`: taking the left element on a tie is what makes the
            // sort stable.
            target[k] = x;
            k += 1;
            i += 1;
        }
    }
    while (i < mid) {
        target[k] = source[i];
        k += 1;
        i += 1;
    }
    while (j < to) {
        target[k] = source[j];
        k += 1;
        j += 1;
    }
}

fn sortByImpl(compare: Value, from_ordering: Value, xs: Value) Error!Value {
    const list = xs.asMutArray();
    if (list.items.len < 2) return xs;

    const scratch = gpa().dupe(Value, list.items) catch oom();
    try mergeFromTo(compare, from_ordering, list.items, scratch, 0, list.items.len);
    return xs;
}

// -- misc --------------------------------------------------------------------

/// `{ value, index }` records, used by `Data.Array.sortWith` and friends.
fn toAssocArrayImpl(xs: Value) Value {
    const items = xs.asMutArray().items;
    const out = gpa().alloc(Value, items.len) catch oom();

    for (items, out, 0..) |x, *slot, i| {
        slot.* = Value.mkRecord(rt.copyFields(&.{
            .{ .name = "value", .value = x },
            .{ .name = "index", .value = Value.mkInt(@intCast(i)) },
        }));
    }
    return Value.mkArray(out);
}

pub const @"ps.new" = rt.effect(newSTArray);

pub const @"ps.unsafeFreezeImpl" = rt.effect(unsafeFreezeImpl);
pub const @"ps.unsafeThawImpl" = rt.effect(unsafeThawImpl);
pub const @"ps.freezeImpl" = rt.effect(freezeImpl);
pub const @"ps.thawImpl" = rt.effect(thawImpl);
pub const @"ps.cloneImpl" = rt.effect(cloneImpl);
pub const @"ps.lengthImpl" = rt.effect(lengthImpl);
pub const @"ps.peekImpl" = rt.effect(peekImpl);
pub const @"ps.pokeImpl" = rt.effect(pokeImpl);
pub const @"ps.pushImpl" = rt.effect(pushImpl);
pub const @"ps.pushAllImpl" = rt.effect(pushAllImpl);
pub const @"ps.unshiftAllImpl" = rt.effect(unshiftAllImpl);
pub const @"ps.popImpl" = rt.effect(popImpl);
pub const @"ps.shiftImpl" = rt.effect(shiftImpl);
pub const @"ps.spliceImpl" = rt.effect(spliceImpl);
pub const @"ps.sortByImpl" = rt.effect(sortByImpl);
pub const @"ps.toAssocArrayImpl" = rt.effect(toAssocArrayImpl);
