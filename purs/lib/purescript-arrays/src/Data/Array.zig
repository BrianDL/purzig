//! FFI for Data.Array.
//!
//! Two of these are dead: `length` and `unsafeIndexImpl` are in the
//! optimizer's `coreForeignSemantics` and become `OpArrayLength` and
//! `OpArrayIndex`. They are written correctly anyway, cheaply.
//!
//! Everything here is non-destructive -- these are the immutable array
//! operations, and the ones that look like mutation (`_updateAt`, `reverse`)
//! copy first, exactly as the `l.slice()` in the originals does. The mutating
//! versions live in `Data/Array/ST.zig`.
//!
//! `sortByImpl` appears in both files and is duplicated rather than shared: an
//! FFI file that imports a sibling breaks as soon as that sibling's module is
//! not part of a build. Note the two differ in one visible way -- this one
//! returns a new array, the ST one sorts in place and returns its argument.

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

// -- creation ----------------------------------------------------------------

/// Inclusive at both ends and counts backwards when `start > end`, so the
/// result is never empty -- `range 3 3` is `[3]`.
fn rangeImpl(start_v: Value, end_v: Value) Value {
    const start: i64 = start_v.asInt();
    const end: i64 = end_v.asInt();
    const step: i64 = if (start > end) -1 else 1;

    const len: usize = @intCast(step * (end - start) + 1);
    const out = gpa().alloc(Value, len) catch oom();

    var i = start;
    var n: usize = 0;
    while (i != end) : (i += step) {
        out[n] = Value.mkInt(@intCast(i));
        n += 1;
    }
    out[n] = Value.mkInt(@intCast(i));
    return Value.mkArray(out);
}

fn replicateImpl(count: Value, v: Value) Value {
    const n = count.asInt();
    if (n < 1) return Value.mkArray(&.{});

    const out = gpa().alloc(Value, @intCast(n)) catch oom();
    for (out) |*slot| slot.* = v;
    return Value.mkArray(out);
}

// A cons list built out of data constructors, so the `foldr` handed to
// `fromFoldableImpl` has something to accumulate into. The tags are never seen
// by PureScript -- the list is threaded through the fold and unwound here.
fn consCell(head: Value, tail: Value) Value {
    return Value.mkData("Cons", rt.copyValues(&.{ head, tail }));
}

const cons_fn = rt.curry(consCell);

/// `listToArray(foldr(curryCons)(emptyList)(xs))`. Building a list first, then
/// converting, is what lets this work for ANY `Foldable` while still producing
/// a flat array: the fold cannot know the final length in advance.
fn fromFoldableImpl(foldr: Value, xs: Value) Error!Value {
    const list = try rt.apply3(foldr, cons_fn, Value.mkData("Nil", &.{}), xs);

    var out: std.ArrayList(Value) = .empty;
    var current = list;
    while (current.hasTag("Cons")) {
        out.append(gpa(), current.arg(0)) catch oom();
        current = current.arg(1);
    }
    return Value.mkArray(out.items);
}

// -- size and non-indexed reads ----------------------------------------------

fn length(xs: Value) Value {
    return Value.mkInt(@intCast(xs.asArray().len));
}

/// `empty` is applied to an empty record rather than called with no arguments:
/// the original's `empty({})` passes a dummy because JavaScript has no unit,
/// and the PureScript type is `Unit -> b`.
fn unconsImpl(empty: Value, next: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    if (items.len == 0) return try rt.apply(empty, Value.mkRecord(&.{}));

    const tail = gpa().dupe(Value, items[1..]) catch oom();
    return try rt.apply2(next, items[0], Value.mkArray(tail));
}

// -- indexed operations ------------------------------------------------------

fn indexImpl(just: Value, nothing: Value, xs: Value, index: Value) Error!Value {
    const items = xs.asArray();
    const i = index.asInt();
    if (i < 0 or i >= items.len) return nothing;
    return try rt.apply(just, items[@intCast(i)]);
}

/// Returns the `Maybe` that `f` produced, not the element -- this is
/// `findMap`, so the result of the successful call is the answer.
fn findMapImpl(nothing: Value, isJust: Value, f: Value, xs: Value) Error!Value {
    for (xs.asArray()) |x| {
        const result = try rt.apply(f, x);
        if ((try rt.apply(isJust, result)).asBool()) return result;
    }
    return nothing;
}

fn findIndexImpl(just: Value, nothing: Value, f: Value, xs: Value) Error!Value {
    for (xs.asArray(), 0..) |x, i| {
        if ((try rt.apply(f, x)).asBool()) return try rt.apply(just, Value.mkInt(@intCast(i)));
    }
    return nothing;
}

fn findLastIndexImpl(just: Value, nothing: Value, f: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if ((try rt.apply(f, items[i])).asBool()) return try rt.apply(just, Value.mkInt(@intCast(i)));
    }
    return nothing;
}

/// Note the bound: inserting AT the length is legal, since it appends. The
/// other two reject it.
fn _insertAt(just: Value, nothing: Value, index: Value, a: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const i = index.asInt();
    if (i < 0 or i > items.len) return nothing;

    const at: usize = @intCast(i);
    const out = gpa().alloc(Value, items.len + 1) catch oom();
    for (out[0..at], items[0..at]) |*slot, x| slot.* = x;
    out[at] = a;
    for (out[at + 1 ..], items[at..]) |*slot, x| slot.* = x;
    return try rt.apply(just, Value.mkArray(out));
}

fn _deleteAt(just: Value, nothing: Value, index: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const i = index.asInt();
    if (i < 0 or i >= items.len) return nothing;

    const at: usize = @intCast(i);
    const out = gpa().alloc(Value, items.len - 1) catch oom();
    for (out[0..at], items[0..at]) |*slot, x| slot.* = x;
    for (out[at..], items[at + 1 ..]) |*slot, x| slot.* = x;
    return try rt.apply(just, Value.mkArray(out));
}

fn _updateAt(just: Value, nothing: Value, index: Value, a: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const i = index.asInt();
    if (i < 0 or i >= items.len) return nothing;

    const out = gpa().dupe(Value, items) catch oom();
    out[@intCast(i)] = a;
    return try rt.apply(just, Value.mkArray(out));
}

// -- transformations ---------------------------------------------------------

fn reverse(xs: Value) Value {
    const items = xs.asArray();
    const out = gpa().alloc(Value, items.len) catch oom();
    for (items, 0..) |x, i| out[items.len - 1 - i] = x;
    return Value.mkArray(out);
}

fn concat(xss: Value) Value {
    const groups = xss.asArray();

    var total: usize = 0;
    for (groups) |group| total += group.asArray().len;

    const out = gpa().alloc(Value, total) catch oom();
    var n: usize = 0;
    for (groups) |group| {
        for (group.asArray()) |x| {
            out[n] = x;
            n += 1;
        }
    }
    return Value.mkArray(out);
}

fn filterImpl(f: Value, xs: Value) Error!Value {
    var out: std.ArrayList(Value) = .empty;
    for (xs.asArray()) |x| {
        if ((try rt.apply(f, x)).asBool()) out.append(gpa(), x) catch oom();
    }
    return Value.mkArray(out.items);
}

fn partitionImpl(f: Value, xs: Value) Error!Value {
    var yes: std.ArrayList(Value) = .empty;
    var no: std.ArrayList(Value) = .empty;

    for (xs.asArray()) |x| {
        if ((try rt.apply(f, x)).asBool()) {
            yes.append(gpa(), x) catch oom();
        } else {
            no.append(gpa(), x) catch oom();
        }
    }

    return Value.mkRecord(rt.copyFields(&.{
        .{ .name = "yes", .value = Value.mkArray(yes.items) },
        .{ .name = "no", .value = Value.mkArray(no.items) },
    }));
}

/// Both scans are the same length as their input and exclude the initial
/// accumulator, which is what distinguishes them from Haskell's.
fn scanlImpl(f: Value, initial: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const out = gpa().alloc(Value, items.len) catch oom();

    var acc = initial;
    for (items, out) |x, *slot| {
        acc = try rt.apply2(f, acc, x);
        slot.* = acc;
    }
    return Value.mkArray(out);
}

fn scanrImpl(f: Value, initial: Value, xs: Value) Error!Value {
    const items = xs.asArray();
    const out = gpa().alloc(Value, items.len) catch oom();

    var acc = initial;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        acc = try rt.apply2(f, items[i], acc);
        out[i] = acc;
    }
    return Value.mkArray(out);
}

// -- sorting -----------------------------------------------------------------

/// Stable bottom-up merge sort. See `Data/Array/ST.zig` for why this is
/// transcribed rather than handed to `std.sort`: stability is contractual and
/// the comparator can throw.
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
    const items = xs.asArray();
    if (items.len < 2) return xs;

    const out = gpa().dupe(Value, items) catch oom();
    const scratch = gpa().dupe(Value, items) catch oom();
    try mergeFromTo(compare, from_ordering, out, scratch, 0, items.len);
    return Value.mkArray(out);
}

// -- subarrays and zipping ---------------------------------------------------

/// `l.slice(s, e)`: negative bounds count from the end, both clamp, and a
/// start at or past the end gives the empty array.
fn sliceImpl(start_v: Value, end_v: Value, xs: Value) Value {
    const items = xs.asArray();
    const len: i64 = @intCast(items.len);

    var s: i64 = start_v.asInt();
    var e: i64 = end_v.asInt();
    if (s < 0) s += len;
    if (e < 0) e += len;
    s = @max(0, @min(s, len));
    e = @max(0, @min(e, len));
    if (s >= e) return Value.mkArray(&.{});

    const from: usize = @intCast(s);
    const to: usize = @intCast(e);
    return Value.mkArray(gpa().dupe(Value, items[from..to]) catch oom());
}

/// Stops at the shorter of the two, so no bounds check is needed inside.
fn zipWithImpl(f: Value, xs: Value, ys: Value) Error!Value {
    const a = xs.asArray();
    const b = ys.asArray();
    const len = @min(a.len, b.len);

    const out = gpa().alloc(Value, len) catch oom();
    for (a[0..len], b[0..len], out) |x, y, *slot| {
        slot.* = try rt.apply2(f, x, y);
    }
    return Value.mkArray(out);
}

// -- folding -----------------------------------------------------------------

fn anyImpl(p: Value, xs: Value) Error!Value {
    for (xs.asArray()) |x| {
        if ((try rt.apply(p, x)).asBool()) return Value.mkBool(true);
    }
    return Value.mkBool(false);
}

fn allImpl(p: Value, xs: Value) Error!Value {
    for (xs.asArray()) |x| {
        if (!(try rt.apply(p, x)).asBool()) return Value.mkBool(false);
    }
    return Value.mkBool(true);
}

/// No bounds check, by contract -- the `Partial` constraint is the check. An
/// out-of-range index panics from the slice rather than returning `undefined`
/// as JavaScript would, which is the better failure of the two.
fn unsafeIndexImpl(xs: Value, index: Value) Value {
    return xs.asArray()[@intCast(index.asInt())];
}

pub const @"ps.rangeImpl" = rt.curry(rangeImpl);
pub const @"ps.replicateImpl" = rt.curry(replicateImpl);
pub const @"ps.fromFoldableImpl" = rt.curry(fromFoldableImpl);
pub const @"ps.length" = rt.curry(length);
pub const @"ps.unconsImpl" = rt.curry(unconsImpl);
pub const @"ps.indexImpl" = rt.curry(indexImpl);
pub const @"ps.findMapImpl" = rt.curry(findMapImpl);
pub const @"ps.findIndexImpl" = rt.curry(findIndexImpl);
pub const @"ps.findLastIndexImpl" = rt.curry(findLastIndexImpl);
pub const @"ps._insertAt" = rt.curry(_insertAt);
pub const @"ps._deleteAt" = rt.curry(_deleteAt);
pub const @"ps._updateAt" = rt.curry(_updateAt);
pub const @"ps.reverse" = rt.curry(reverse);
pub const @"ps.concat" = rt.curry(concat);
pub const @"ps.filterImpl" = rt.curry(filterImpl);
pub const @"ps.partitionImpl" = rt.curry(partitionImpl);
pub const @"ps.scanlImpl" = rt.curry(scanlImpl);
pub const @"ps.scanrImpl" = rt.curry(scanrImpl);
pub const @"ps.sortByImpl" = rt.curry(sortByImpl);
pub const @"ps.sliceImpl" = rt.curry(sliceImpl);
pub const @"ps.zipWithImpl" = rt.curry(zipWithImpl);
pub const @"ps.anyImpl" = rt.curry(anyImpl);
pub const @"ps.allImpl" = rt.curry(allImpl);
pub const @"ps.unsafeIndexImpl" = rt.curry(unsafeIndexImpl);
