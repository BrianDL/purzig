//! FFI for Data.String.Common.
//!
//! `Pattern` and `Replacement` are newtypes, so they arrive erased, as plain
//! string `Value`s.
//!
//! Four deliberate divergences from the JavaScript, all of the same kind --
//! JavaScript's string methods carry the whole Unicode database and the ECMA
//! locale machinery with them, and this runtime does not:
//!
//!   * `toLower`/`toUpper` map ASCII only. `toUpper "ß"` is `"ß"` here and
//!     `"SS"` in the JavaScript backend.
//!   * `trim` strips the ASCII whitespace set plus NBSP, not the full
//!     `WhiteSpace ∪ LineTerminator` production.
//!   * `_localeCompare` compares by code point, ignoring locale entirely. The
//!     PureScript wrapper is `localeCompare`, whose documented contract is
//!     already "locale-dependent", so a stable order satisfies the type if not
//!     the intent.
//!   * `replace`/`replaceAll` treat the replacement as literal text. JavaScript
//!     expands `$&`, `$1` and friends inside it.
//!
//! The empty-pattern cases are NOT a divergence and are transcribed
//! deliberately: `"abc".replace("", "X")` is `"Xabc"`, and `replaceAll` with an
//! empty pattern goes through a global regexp that matches at every boundary,
//! giving `"XaXbXcX"`. Both fall out of the original and both are exercised by
//! the fixture.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

fn appendStr(out: *std.ArrayList(u8), bytes: []const u8) void {
    out.appendSlice(rt.alloc(), bytes) catch @panic("runtime: out of memory");
}

// -- comparison -------------------------------------------------------------

/// Arity five, returning one of the three `Ordering` constructors it is handed
/// -- the same shape as `Data.Ord`'s scalar comparisons, and for the same
/// reason: the FFI never learns how `Ordering` is represented.
fn _localeCompare(lt: Value, eq: Value, gt: Value, s1: Value, s2: Value) Value {
    return switch (std.mem.order(u8, s1.asString(), s2.asString())) {
        .lt => lt,
        .eq => eq,
        .gt => gt,
    };
}

// -- replacement ------------------------------------------------------------

/// `s.replace(pattern, replacement)` with a string pattern: the FIRST
/// occurrence only.
fn replace(pattern: Value, replacement: Value, str: Value) Value {
    const s = str.asString();
    const needle = pattern.asString();
    const rep = replacement.asString();

    var out: std.ArrayList(u8) = .empty;
    if (needle.len == 0) {
        appendStr(&out, rep);
        appendStr(&out, s);
        return Value.mkString(out.items);
    }

    const at = std.mem.indexOf(u8, s, needle) orelse return Value.mkString(s);
    appendStr(&out, s[0..at]);
    appendStr(&out, rep);
    appendStr(&out, s[at + needle.len ..]);
    return Value.mkString(out.items);
}

/// Every occurrence, scanning left to right and never re-examining what was
/// just replaced -- which is what the global regexp in the original does.
fn replaceAll(pattern: Value, replacement: Value, str: Value) Value {
    const s = str.asString();
    const needle = pattern.asString();
    const rep = replacement.asString();

    var out: std.ArrayList(u8) = .empty;

    // An empty pattern matches at every code point boundary, including both
    // ends. Boundaries, not bytes, so a multi-byte character is not split.
    if (needle.len == 0) {
        appendStr(&out, rep);
        var i: usize = 0;
        while (i < s.len) {
            const n = seqLen(s[i]);
            appendStr(&out, s[i..@min(i + n, s.len)]);
            appendStr(&out, rep);
            i += n;
        }
        return Value.mkString(out.items);
    }

    var rest = s;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        appendStr(&out, rest[0..at]);
        appendStr(&out, rep);
        rest = rest[at + needle.len ..];
    }
    appendStr(&out, rest);
    return Value.mkString(out.items);
}

// -- splitting and joining --------------------------------------------------

/// `s.split(sep)`. Two edge cases are load-bearing and both come straight from
/// the specification: an empty separator explodes the string into single
/// characters, and splitting an EMPTY string by an empty separator gives the
/// empty array rather than one empty string.
fn split(separator: Value, str: Value) Value {
    const s = str.asString();
    const sep = separator.asString();

    var out: std.ArrayList(Value) = .empty;
    const gpa = rt.alloc();

    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            const n = @min(seqLen(s[i]), s.len - i);
            out.append(gpa, Value.mkString(s[i .. i + n])) catch @panic("runtime: out of memory");
            i += n;
        }
        return Value.mkArray(out.items);
    }

    var rest = s;
    while (std.mem.indexOf(u8, rest, sep)) |at| {
        out.append(gpa, Value.mkString(rest[0..at])) catch @panic("runtime: out of memory");
        rest = rest[at + sep.len ..];
    }
    out.append(gpa, Value.mkString(rest)) catch @panic("runtime: out of memory");
    return Value.mkArray(out.items);
}

fn joinWith(separator: Value, xs: Value) Value {
    const sep = separator.asString();
    const items = xs.asArray();

    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) appendStr(&out, sep);
        appendStr(&out, item.asString());
    }
    return Value.mkString(out.items);
}

// -- case and whitespace ----------------------------------------------------

fn toLower(str: Value) Value {
    const s = str.asString();
    const out = rt.alloc().dupe(u8, s) catch @panic("runtime: out of memory");
    for (out) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
    }
    return Value.mkString(out);
}

fn toUpper(str: Value) Value {
    const s = str.asString();
    const out = rt.alloc().dupe(u8, s) catch @panic("runtime: out of memory");
    for (out) |*c| {
        if (c.* >= 'a' and c.* <= 'z') c.* -= 32;
    }
    return Value.mkString(out);
}

fn isSpace(s: []const u8, i: usize) ?usize {
    return switch (s[i]) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => 1,
        // U+00A0 NO-BREAK SPACE, the one non-ASCII space common enough in real
        // text to be worth two bytes of special-casing.
        0xC2 => if (i + 1 < s.len and s[i + 1] == 0xA0) 2 else null,
        else => null,
    };
}

fn trim(str: Value) Value {
    const s = str.asString();

    var start: usize = 0;
    while (start < s.len) {
        const n = isSpace(s, start) orelse break;
        start += n;
    }

    var end = s.len;
    while (end > start) {
        // Step back over one character, then test it.
        var at = end - 1;
        while (at > start and s[at] & 0xC0 == 0x80) at -= 1;
        const n = isSpace(s, at) orelse break;
        if (at + n != end) break;
        end = at;
    }

    return Value.mkString(s[start..end]);
}

pub const @"ps._localeCompare" = rt.curry(_localeCompare);
pub const @"ps.replace" = rt.curry(replace);
pub const @"ps.replaceAll" = rt.curry(replaceAll);
pub const @"ps.split" = rt.curry(split);
pub const @"ps.toLower" = rt.curry(toLower);
pub const @"ps.toUpper" = rt.curry(toUpper);
pub const @"ps.trim" = rt.curry(trim);
pub const @"ps.joinWith" = rt.curry(joinWith);

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
