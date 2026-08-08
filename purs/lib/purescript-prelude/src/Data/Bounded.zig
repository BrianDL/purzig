//! FFI for Data.Bounded.
//!
//! These are values, not functions, so they are written directly rather than
//! through `rt.curry`.
//!
//! `topChar` is 0xFFFF because PureScript's Char is a UTF-16 code unit and the
//! JavaScript implementation is `String.fromCharCode(65535)`. Our Char is a
//! u21 and could physically hold more, but agreeing with the other backends
//! matters more than the extra range.

const std = @import("std");
const rt = @import("runtime");
const Value = rt.Value;

pub const @"ps.topInt" = Value.mkInt(2147483647);
pub const @"ps.bottomInt" = Value.mkInt(-2147483648);

pub const @"ps.topChar" = Value.mkChar(0xFFFF);
pub const @"ps.bottomChar" = Value.mkChar(0);

pub const @"ps.topNumber" = Value.mkNumber(std.math.inf(f64));
pub const @"ps.bottomNumber" = Value.mkNumber(-std.math.inf(f64));
