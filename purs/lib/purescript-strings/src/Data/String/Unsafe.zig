//! FFI for Data.String.Unsafe.
//!
//! Both of these are partial in the original and signal failure by throwing a
//! JavaScript `Error`. Here they panic instead.
//!
//! That is the call `rt.forceLazy` already makes for a cycle, and for the same
//! reason: the 0.15.0 release notes tell backends to make the error appropriate
//! for their target, and a violated precondition on a function whose module is
//! named `Unsafe` is a defect in the calling program rather than a condition to
//! recover from. The cost is that these are not catchable by
//! `Effect.Exception.catchException`, where in JavaScript they would be.
//!
//! Indices count CODE POINTS, not bytes. See `CodeUnits.zig` for why.

const rt = @import("runtime");
const Value = rt.Value;

fn charAt(index: Value, str: Value) Value {
    const s = str.asString();
    const i = index.asInt();
    if (i < 0) @panic("Data.String.Unsafe.charAt: Invalid index.");

    const at = byteIndexOf(s, @intCast(i));
    if (at >= s.len) @panic("Data.String.Unsafe.charAt: Invalid index.");
    return Value.mkChar(decodeAt(s, at));
}

fn char(str: Value) Value {
    const s = str.asString();
    if (countCodePoints(s) != 1) {
        @panic("Data.String.Unsafe.char: Expected string of length 1.");
    }
    return Value.mkChar(decodeAt(s, 0));
}

pub const @"ps.charAt" = rt.curry(charAt);
pub const @"ps.char" = rt.curry(char);

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
