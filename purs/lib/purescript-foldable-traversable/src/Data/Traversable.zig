//! FFI for Data.Traversable.
//!
//! `traverseArrayImpl` is the one genuinely intricate function in this package,
//! and the shape is load-bearing rather than incidental, so it is transcribed
//! structurally rather than rewritten as a loop.
//!
//! The naive definition is a right fold building `f x <*> rest`, which nests
//! `apply` to the depth of the array. The original instead splits the array in
//! half and combines the two halves with `concat2`, so the `Applicative`
//! actions form a balanced tree of depth log n. For an `Applicative` whose
//! `apply` is cheap that only saves stack; for one where it is not -- a parser,
//! a validation collecting errors -- it changes the asymptotics of the
//! traversal itself. Rewriting it as a loop would silently take that away.
//!
//! The cases for 0 to 3 elements are the leaves of that tree, and the pivot
//! `bot + floor((top - bot) / 4) * 2` picks an even split so the two halves
//! bottom out evenly. Both are copied exactly.
//!
//! `apply`, `map` and `pure` arrive as the dictionary's own methods, so this
//! never learns which `Applicative` it is traversing in.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- the small array constructors the original defines inline ---------------

fn array1(a: Value) Value {
    return Value.mkArray(rt.copyValues(&.{a}));
}

fn array2(a: Value, b: Value) Value {
    return Value.mkArray(rt.copyValues(&.{ a, b }));
}

fn array3(a: Value, b: Value, c: Value) Value {
    return Value.mkArray(rt.copyValues(&.{ a, b, c }));
}

fn concat2(xs: Value, ys: Value) Value {
    const a = xs.asArray();
    const b = ys.asArray();

    const out = rt.alloc().alloc(Value, a.len + b.len) catch @panic("runtime: out of memory");
    for (out[0..a.len], a) |*slot, x| slot.* = x;
    for (out[a.len..], b) |*slot, y| slot.* = y;
    return Value.mkArray(out);
}

// Curried once at container level, so the closure chain is built at comptime
// rather than on every call.
const array1_fn = rt.curry(array1);
const array2_fn = rt.curry(array2);
const array3_fn = rt.curry(array3);
const concat2_fn = rt.curry(concat2);

/// The `go(bot, top)` of the original, threading the three dictionary methods
/// it needs rather than closing over them.
fn go(
    apply_fn: Value,
    map_fn: Value,
    pure_fn: Value,
    f: Value,
    array: []const Value,
    bot: usize,
    top: usize,
) Error!Value {
    return switch (top - bot) {
        0 => try rt.apply(pure_fn, Value.mkArray(&.{})),

        1 => try rt.apply2(map_fn, array1_fn, try rt.apply(f, array[bot])),

        2 => try rt.apply2(
            apply_fn,
            try rt.apply2(map_fn, array2_fn, try rt.apply(f, array[bot])),
            try rt.apply(f, array[bot + 1]),
        ),

        3 => try rt.apply2(
            apply_fn,
            try rt.apply2(
                apply_fn,
                try rt.apply2(map_fn, array3_fn, try rt.apply(f, array[bot])),
                try rt.apply(f, array[bot + 1]),
            ),
            try rt.apply(f, array[bot + 2]),
        ),

        else => blk: {
            const pivot = bot + ((top - bot) / 4) * 2;
            const left = try go(apply_fn, map_fn, pure_fn, f, array, bot, pivot);
            const right = try go(apply_fn, map_fn, pure_fn, f, array, pivot, top);
            break :blk try rt.apply2(
                apply_fn,
                try rt.apply2(map_fn, concat2_fn, left),
                right,
            );
        },
    };
}

fn traverseArrayImpl(apply_fn: Value, map_fn: Value, pure_fn: Value, f: Value, array: Value) Error!Value {
    const items = array.asArray();
    return go(apply_fn, map_fn, pure_fn, f, items, 0, items.len);
}

pub const @"ps.traverseArrayImpl" = rt.curry(traverseArrayImpl);
