//! FFI for Data.HeytingAlgebra.
//!
//! These are strict. JavaScript's `&&` and `||` short-circuit, but both
//! arguments arrive already evaluated in every backend, because PureScript is
//! strict -- `conj` and `disj` are ordinary functions, not control flow.

const rt = @import("runtime");
const Value = rt.Value;

fn boolConj(a: Value, b: Value) Value {
    return Value.mkBool(a.asBool() and b.asBool());
}

fn boolDisj(a: Value, b: Value) Value {
    return Value.mkBool(a.asBool() or b.asBool());
}

fn boolNot(a: Value) Value {
    return Value.mkBool(!a.asBool());
}

pub const @"ps.boolConj" = rt.curry(boolConj);
pub const @"ps.boolDisj" = rt.curry(boolDisj);
pub const @"ps.boolNot" = rt.curry(boolNot);
