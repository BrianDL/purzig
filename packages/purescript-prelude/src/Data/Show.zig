//! FFI for Data.Show.
//!
//! The escaping rules are Haskell's, not Zig's, and are transcribed from the
//! JavaScript implementation rather than approximated:
//!
//!   * Control characters below 0x20, plus 0x7F, become `\a \b \f \n \r \t \v`
//!     where a mnemonic exists and `\<decimal>` otherwise.
//!   * A decimal escape immediately followed by a digit gets a `\&` separator,
//!     so `show "\1" <> "2"` cannot be misread as `\12`.
//!   * `showNumber` appends `.0` to anything that looks like an integer, so
//!     `show 1.0` is `"1.0"` rather than `"1"`.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

fn allocPrint(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(rt.alloc(), fmt, args) catch @panic("runtime: out of memory");
}

fn showIntImpl(x: Value) Value {
    return Value.mkString(allocPrint("{d}", .{x.asInt()}));
}

/// JS decides with `isNaN(str + ".0")`: appending only succeeds for a plain
/// integer form, so anything already carrying a `.`, an exponent, or a word
/// like `Infinity` is left alone.
fn showNumberImpl(x: Value) Value {
    const str = allocPrint("{d}", .{x.asNumber()});

    var plain = str.len > 0;
    for (str, 0..) |c, i| {
        const digit = c >= '0' and c <= '9';
        const sign = i == 0 and c == '-';
        if (!digit and !sign) {
            plain = false;
            break;
        }
    }

    if (!plain) return Value.mkString(str);
    return Value.mkString(allocPrint("{s}.0", .{str}));
}

fn mnemonic(code: u21) ?[]const u8 {
    return switch (code) {
        0x07 => "\\a",
        0x08 => "\\b",
        0x0C => "\\f",
        0x0A => "\\n",
        0x0D => "\\r",
        0x09 => "\\t",
        0x0B => "\\v",
        else => null,
    };
}

fn showCharImpl(x: Value) Value {
    const code = x.asChar();

    if (code < 0x20 or code == 0x7F) {
        if (mnemonic(code)) |m| return Value.mkString(allocPrint("'{s}'", .{m}));
        return Value.mkString(allocPrint("'\\{d}'", .{code}));
    }

    if (code == '\'' or code == '\\') {
        return Value.mkString(allocPrint("'\\{u}'", .{code}));
    }
    return Value.mkString(allocPrint("'{u}'", .{code}));
}

fn showStringImpl(x: Value) Value {
    const s = x.asString();

    var out: std.ArrayList(u8) = .empty;
    const gpa = rt.alloc();
    out.append(gpa, '"') catch @panic("runtime: out of memory");

    for (s, 0..) |c, i| {
        const needs_escape = c < 0x20 or c == 0x7F or c == '"' or c == '\\';
        if (!needs_escape) {
            out.append(gpa, c) catch @panic("runtime: out of memory");
            continue;
        }

        if (c == '"' or c == '\\') {
            out.appendSlice(gpa, &.{ '\\', c }) catch @panic("runtime: out of memory");
            continue;
        }

        if (mnemonic(c)) |m| {
            out.appendSlice(gpa, m) catch @panic("runtime: out of memory");
            continue;
        }

        // Decimal escape. If the next character is a digit, `\&` keeps the two
        // from running together when the shown string is read back.
        const next_is_digit = i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '9';
        const escape = if (next_is_digit)
            allocPrint("\\{d}\\&", .{c})
        else
            allocPrint("\\{d}", .{c});
        out.appendSlice(gpa, escape) catch @panic("runtime: out of memory");
    }

    out.append(gpa, '"') catch @panic("runtime: out of memory");
    return Value.mkString(out.items);
}

/// Fallible: `f` is the element `show`, which is PureScript code and may throw.
fn showArrayImpl(f: Value, xs: Value) rt.Error!Value {
    const items = xs.asArray();

    var out: std.ArrayList(u8) = .empty;
    const gpa = rt.alloc();
    out.append(gpa, '[') catch @panic("runtime: out of memory");

    for (items, 0..) |x, i| {
        if (i > 0) out.append(gpa, ',') catch @panic("runtime: out of memory");
        out.appendSlice(gpa, (try rt.apply(f, x)).asString()) catch @panic("runtime: out of memory");
    }

    out.append(gpa, ']') catch @panic("runtime: out of memory");
    return Value.mkString(out.items);
}

pub const @"ps.showIntImpl" = rt.curry(showIntImpl);
pub const @"ps.showNumberImpl" = rt.curry(showNumberImpl);
pub const @"ps.showCharImpl" = rt.curry(showCharImpl);
pub const @"ps.showStringImpl" = rt.curry(showStringImpl);
pub const @"ps.showArrayImpl" = rt.curry(showArrayImpl);
