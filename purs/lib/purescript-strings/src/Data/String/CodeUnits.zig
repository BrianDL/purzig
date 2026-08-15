//! FFI for Data.String.CodeUnits.
//!
//! ## What a "code unit" is here
//!
//! PureScript's `String` is UTF-16 and this module indexes it by UTF-16 code
//! unit. Our `Value.string` is UTF-8 and our `Char` is a `u21`, so an exact
//! match is not available and a choice has to be made. **A code unit here is
//! one Unicode code point.**
//!
//! The alternative was to index by byte, which is what the 08-08 handoff's
//! "String is UTF-8, not UTF-16" note anticipated. Code points win on three
//! counts:
//!
//!   * `fromCharArray <<< toCharArray` is the identity. Byte indexing breaks
//!     it: "é" decomposes into two `Char`s of 0xC3 and 0xA9, which re-encode as
//!     four bytes.
//!   * `charAt` yields a real character rather than half of one.
//!   * It AGREES with UTF-16 for the whole Basic Multilingual Plane, where byte
//!     indexing disagrees on everything above ASCII. The remaining divergence
//!     is the astral planes, where JavaScript counts a surrogate pair as two
//!     and we count the code point as one -- so `length "<emoji>"` is 1 here
//!     and 2 in the JavaScript backend.
//!
//! The cost is that indexing is O(n) rather than O(1), which is why `take`,
//! `drop` and `slice` walk the string. Switching to bytes is a change to the
//! helpers at the bottom of this file and nothing else.
//!
//! ## Index clamping
//!
//! The originals inherit their out-of-range behaviour from `String.prototype`,
//! which never throws: `substring` clamps both ends, `substr` treats a negative
//! length as zero, and `slice` counts a negative index from the end. Those
//! rules are reproduced explicitly below rather than approximated, because
//! `Data.String.CodeUnits` exposes them directly.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- construction and conversion --------------------------------------------

fn singleton(c: Value) Value {
    return Value.mkString(encode(c.asChar()));
}

fn fromCharArray(a: Value) Value {
    const items = a.asArray();
    var out: std.ArrayList(u8) = .empty;
    const gpa = rt.alloc();
    for (items) |item| {
        out.appendSlice(gpa, encode(item.asChar())) catch @panic("runtime: out of memory");
    }
    return Value.mkString(out.items);
}

fn toCharArray(str: Value) Value {
    const s = str.asString();
    var out: std.ArrayList(Value) = .empty;
    const gpa = rt.alloc();

    var i: usize = 0;
    while (i < s.len) {
        out.append(gpa, Value.mkChar(decodeAt(s, i))) catch @panic("runtime: out of memory");
        i += seqLen(s[i]);
    }
    return Value.mkArray(out.items);
}

// -- indexing ---------------------------------------------------------------

fn length(str: Value) Value {
    return Value.mkInt(@intCast(countCodePoints(str.asString())));
}

fn _charAt(just: Value, nothing: Value, index: Value, str: Value) Error!Value {
    const s = str.asString();
    const i = index.asInt();
    if (i < 0) return nothing;

    const at = byteIndexOf(s, @intCast(i));
    if (at >= s.len) return nothing;
    return try rt.apply(just, Value.mkChar(decodeAt(s, at)));
}

fn _toChar(just: Value, nothing: Value, str: Value) Error!Value {
    const s = str.asString();
    if (countCodePoints(s) != 1) return nothing;
    return try rt.apply(just, Value.mkChar(decodeAt(s, 0)));
}

/// Note this one is fallible for a second reason: the predicate is PureScript
/// code and may throw.
fn countPrefix(p: Value, str: Value) Error!Value {
    const s = str.asString();
    var i: usize = 0;
    var n: i32 = 0;
    while (i < s.len) {
        const matched = (try rt.apply(p, Value.mkChar(decodeAt(s, i)))).asBool();
        if (!matched) break;
        i += seqLen(s[i]);
        n += 1;
    }
    return Value.mkInt(n);
}

// -- searching --------------------------------------------------------------

fn _indexOf(just: Value, nothing: Value, pattern: Value, str: Value) Error!Value {
    const s = str.asString();
    const at = std.mem.indexOf(u8, s, pattern.asString()) orelse return nothing;
    return try rt.apply(just, Value.mkInt(@intCast(codePointIndexOf(s, at))));
}

/// `indexOf(x, startAt)` in JavaScript, but with the out-of-range guard the
/// PureScript wrapper relies on: a start before the beginning or past the end
/// is `Nothing` rather than a clamped search.
fn _indexOfStartingAt(just: Value, nothing: Value, pattern: Value, start: Value, str: Value) Error!Value {
    const s = str.asString();
    const from = start.asInt();
    if (from < 0 or from > countCodePoints(s)) return nothing;

    const begin = byteIndexOf(s, @intCast(from));
    const found = std.mem.indexOf(u8, s[begin..], pattern.asString()) orelse return nothing;
    return try rt.apply(just, Value.mkInt(@intCast(codePointIndexOf(s, begin + found))));
}

fn _lastIndexOf(just: Value, nothing: Value, pattern: Value, str: Value) Error!Value {
    const s = str.asString();
    const at = std.mem.lastIndexOf(u8, s, pattern.asString()) orelse return nothing;
    return try rt.apply(just, Value.mkInt(@intCast(codePointIndexOf(s, at))));
}

/// `lastIndexOf(x, startAt)` searches backwards from `startAt`, so the match
/// may BEGIN at `startAt` but not after it. Unlike `_indexOfStartingAt` there
/// is no range guard in the original -- a negative start simply finds nothing
/// but an empty pattern at 0, and a start past the end searches the whole
/// string.
fn _lastIndexOfStartingAt(just: Value, nothing: Value, pattern: Value, start: Value, str: Value) Error!Value {
    const s = str.asString();
    const needle = pattern.asString();

    const from = start.asInt();
    const limit: usize = if (from < 0) 0 else byteIndexOf(s, @intCast(from));

    // The match must start at or before `limit`, so search the prefix that
    // extends one whole needle past it.
    const end = @min(s.len, limit + needle.len);
    const at = std.mem.lastIndexOf(u8, s[0..end], needle) orelse return nothing;
    if (at > limit) return nothing;
    return try rt.apply(just, Value.mkInt(@intCast(codePointIndexOf(s, at))));
}

// -- slicing ----------------------------------------------------------------

/// `s.substr(0, n)`: a negative length yields the empty string.
fn take(count: Value, str: Value) Value {
    const s = str.asString();
    const n = count.asInt();
    if (n <= 0) return Value.mkString("");
    return Value.mkString(s[0..byteIndexOf(s, @intCast(n))]);
}

/// `s.substring(n)`: clamps, so a negative count drops nothing.
fn drop(count: Value, str: Value) Value {
    const s = str.asString();
    const n = count.asInt();
    if (n <= 0) return Value.mkString(s);
    return Value.mkString(s[byteIndexOf(s, @intCast(n))..]);
}

/// `s.slice(b, e)`. Negative bounds count back from the end, both are clamped,
/// and a start at or after the end yields the empty string. Note this differs
/// from `substring`, which would swap the two.
fn slice(begin: Value, end: Value, str: Value) Value {
    const s = str.asString();
    const len: i64 = @intCast(countCodePoints(s));

    var b: i64 = begin.asInt();
    var e: i64 = end.asInt();
    if (b < 0) b += len;
    if (e < 0) e += len;
    b = @max(0, @min(b, len));
    e = @max(0, @min(e, len));
    if (b >= e) return Value.mkString("");

    return Value.mkString(s[byteIndexOf(s, @intCast(b))..byteIndexOf(s, @intCast(e))]);
}

/// Two `substring` calls, so the index is clamped at both ends and the two
/// halves always concatenate back to the original.
fn splitAt(index: Value, str: Value) Value {
    const s = str.asString();
    const i = index.asInt();
    const at = if (i <= 0) 0 else byteIndexOf(s, @intCast(i));

    return Value.mkRecord(rt.copyFields(&.{
        .{ .name = "before", .value = Value.mkString(s[0..at]) },
        .{ .name = "after", .value = Value.mkString(s[at..]) },
    }));
}

pub const @"ps.singleton" = rt.curry(singleton);
pub const @"ps.fromCharArray" = rt.curry(fromCharArray);
pub const @"ps.toCharArray" = rt.curry(toCharArray);
pub const @"ps.length" = rt.curry(length);
pub const @"ps._charAt" = rt.curry(_charAt);
pub const @"ps._toChar" = rt.curry(_toChar);
pub const @"ps.countPrefix" = rt.curry(countPrefix);
pub const @"ps._indexOf" = rt.curry(_indexOf);
pub const @"ps._indexOfStartingAt" = rt.curry(_indexOfStartingAt);
pub const @"ps._lastIndexOf" = rt.curry(_lastIndexOf);
pub const @"ps._lastIndexOfStartingAt" = rt.curry(_lastIndexOfStartingAt);
pub const @"ps.take" = rt.curry(take);
pub const @"ps.drop" = rt.curry(drop);
pub const @"ps.slice" = rt.curry(slice);
pub const @"ps.splitAt" = rt.curry(splitAt);

// -- UTF-8 helpers ----------------------------------------------------------
//
// Repeated verbatim in the other FFI files of this package rather than shared
// through an import. The driver copies `<Module>.zig` beside each module it
// compiles, so a helper file that is not itself a module's sibling would never
// reach the output directory, and importing another module's `.ffi.zig` would
// break as soon as that module is not part of a given build. A self-contained
// FFI file is what makes the beside-the-source convention work.

/// Bytes in the sequence starting with `b`. An invalid lead byte counts as one,
/// so a malformed string is traversed rather than rejected -- these functions
/// are total in PureScript and must stay total here.
fn seqLen(b: u8) usize {
    return switch (b) {
        0x00...0x7F => 1,
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1,
    };
}

/// The code point beginning at byte `at`. Falls back to the raw byte when the
/// sequence is truncated or malformed.
pub fn decodeAt(s: []const u8, at: usize) u21 {
    const n = seqLen(s[at]);
    if (n == 1 or at + n > s.len) return s[at];

    var cp: u21 = switch (n) {
        2 => s[at] & 0x1F,
        3 => s[at] & 0x0F,
        else => s[at] & 0x07,
    };
    for (s[at + 1 .. at + n]) |b| {
        if (b & 0xC0 != 0x80) return s[at];
        cp = (cp << 6) | (b & 0x3F);
    }
    return cp;
}

pub fn countCodePoints(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) i += seqLen(s[i]);
    return n;
}

/// Byte offset of code point `n`, or `s.len` if the string is shorter. Clamping
/// rather than erroring is what lets `take`, `drop` and `slice` inherit
/// JavaScript's out-of-range behaviour for free.
pub fn byteIndexOf(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < s.len and seen < n) : (seen += 1) i += seqLen(s[i]);
    return i;
}

/// Inverse of `byteIndexOf`: how many code points precede byte offset `at`.
pub fn codePointIndexOf(s: []const u8, at: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < at and i < s.len) : (n += 1) i += seqLen(s[i]);
    return n;
}

/// UTF-8 encode one code point into the arena.
pub fn encode(cp: u21) []const u8 {
    var buf: [4]u8 = undefined;
    const n: usize = if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4;
    switch (n) {
        1 => buf[0] = @intCast(cp),
        2 => {
            buf[0] = @intCast(0xC0 | (cp >> 6));
            buf[1] = @intCast(0x80 | (cp & 0x3F));
        },
        3 => {
            buf[0] = @intCast(0xE0 | (cp >> 12));
            buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[2] = @intCast(0x80 | (cp & 0x3F));
        },
        else => {
            buf[0] = @intCast(0xF0 | (cp >> 18));
            buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[3] = @intCast(0x80 | (cp & 0x3F));
        },
    }
    return rt.alloc().dupe(u8, buf[0..n]) catch @panic("runtime: out of memory");
}
