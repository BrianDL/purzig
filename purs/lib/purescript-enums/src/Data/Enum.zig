//! FFI for Data.Enum.
//!
//! Both of these are about `Char`, which is a `u21` here and a UTF-16 code unit
//! in JavaScript.
//!
//! `fromCharCode` masks to 16 bits, matching `String.fromCharCode`. That is not
//! an accident of the original being JavaScript -- `Data.Bounded.topChar` is
//! already 0xFFFF in this backend, chosen so `Char` agrees with the other
//! backends rather than with what our representation could hold. Masking keeps
//! `fromCharCode` inside that same range, and `Data.Char.toEnum` guards the
//! range before ever calling it, so the mask is only reachable through the
//! unchecked path.

const rt = @import("runtime");
const Value = rt.Value;

fn toCharCode(c: Value) Value {
    return Value.mkInt(@intCast(c.asChar()));
}

fn fromCharCode(code: Value) Value {
    const masked: u16 = @truncate(@as(u32, @bitCast(code.asInt())));
    return Value.mkChar(masked);
}

pub const @"ps.toCharCode" = rt.curry(toCharCode);
pub const @"ps.fromCharCode" = rt.curry(fromCharCode);
