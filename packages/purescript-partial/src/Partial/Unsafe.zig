//! FFI for Partial.Unsafe.
//!
//! `unsafePartial :: (Partial => a) -> a` discharges a `Partial` constraint. A
//! constrained value is compiled as a function of its dictionary, and the
//! `Partial` dictionary is empty, so discharging it means applying the function
//! to an empty record.
//!
//! In JavaScript the erased dictionary leaves a nullary function and the
//! original writes `f()`. Here the argument is still there, so this applies
//! `Value.mkRecord(&.{})` explicitly.
//!
//! Usually dead code: the optimizer's `partial_unsafe_unsafePartial` rewrites
//! `unsafePartial (\_ -> body)` by substituting the empty record directly, and
//! that covers every literal use. It falls through to this function only when
//! the argument is not a syntactic lambda -- `unsafePartial (f x)`, say -- which
//! real code does occasionally do.

const rt = @import("runtime");
const Value = rt.Value;

fn _unsafePartial(f: Value) rt.Error!Value {
    // An empty field slice is comptime-known, so unlike a populated record this
    // one needs no `rt.copyFields`: there is no stack temporary to dangle.
    return try rt.apply(f, Value.mkRecord(&.{}));
}

pub const @"ps._unsafePartial" = rt.curry(_unsafePartial);
