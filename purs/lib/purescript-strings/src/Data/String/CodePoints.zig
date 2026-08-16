//! FFI for Data.String.CodePoints.
//!
//! Every function in this module takes a PureScript `fallback` as its first
//! argument. In JavaScript that fallback is used only when the engine lacks
//! `Symbol.iterator`, `Array.from` or `String.fromCodePoint`; on a modern
//! engine the native path runs instead.
//!
//! **Here the fallback is always the right answer**, and this file is little
//! more than a set of forwarders. The reason is `Data.String.CodeUnits`: the
//! fallbacks are written in terms of it, and a "code unit" in this backend is
//! already one Unicode code point (see `CodeUnits.zig`). The surrogate
//! arithmetic they perform is therefore inert -- `isLead` is false for every
//! character a valid UTF-8 string can produce -- and each fallback degenerates
//! to exactly the code-point operation this module wants.
//!
//! So the native path the original prefers is the one that would be WRONG here.
//! It exists to reconstruct code points from UTF-16 pairs, and there are no
//! pairs to reconstruct.
//!
//! The cost is that these run PureScript rather than Zig, walking the string
//! once per operation. If any of them ever shows up in a profile, the fix is to
//! implement it directly over the UTF-8 bytes with the helper block from
//! `CodeUnits.zig` -- the semantics are already pinned by the fixture.
//!
//! `_toCodePointArray` is additionally in the optimizer's
//! `coreForeignSemantics`, but only for a literal string argument, so this is
//! still the path taken by anything computed.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

/// `CodePoint` is a newtype over `Int`, so it arrives erased.
fn _singleton(fallback: Value, cp: Value) Error!Value {
    return rt.apply(fallback, cp);
}

fn _toCodePointArray(fallback: Value, unsafeCodePointAt0: Value, str: Value) Error!Value {
    _ = unsafeCodePointAt0;
    return rt.apply(fallback, str);
}

fn _unsafeCodePointAt0(fallback: Value, str: Value) Error!Value {
    return rt.apply(fallback, str);
}

fn _codePointAt(
    fallback: Value,
    just: Value,
    nothing: Value,
    unsafeCodePointAt0: Value,
    index: Value,
    str: Value,
) Error!Value {
    _ = just;
    _ = nothing;
    _ = unsafeCodePointAt0;
    return rt.apply2(fallback, index, str);
}

fn _countPrefix(fallback: Value, unsafeCodePointAt0: Value, pred: Value, str: Value) Error!Value {
    _ = unsafeCodePointAt0;
    return rt.apply2(fallback, pred, str);
}

fn _take(fallback: Value, n: Value, str: Value) Error!Value {
    return rt.apply2(fallback, n, str);
}

/// The one that is not a forwarder, because its "fallback" is not a fallback:
/// `singleton` is a per-element function, and both branches of the original map
/// it over the array and join. Doing that here saves building an intermediate
/// array of one-character strings.
fn _fromCodePointArray(singleton: Value, cps: Value) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    const gpa = rt.alloc();

    for (cps.asArray()) |cp| {
        const piece = try rt.apply(singleton, cp);
        out.appendSlice(gpa, piece.asString()) catch @panic("runtime: out of memory");
    }
    return Value.mkString(out.items);
}

pub const @"ps._singleton" = rt.curry(_singleton);
pub const @"ps._fromCodePointArray" = rt.curry(_fromCodePointArray);
pub const @"ps._toCodePointArray" = rt.curry(_toCodePointArray);
pub const @"ps._codePointAt" = rt.curry(_codePointAt);
pub const @"ps._countPrefix" = rt.curry(_countPrefix);
pub const @"ps._take" = rt.curry(_take);
pub const @"ps._unsafeCodePointAt0" = rt.curry(_unsafeCodePointAt0);
