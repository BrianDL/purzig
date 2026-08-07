//! Public surface of the runtime. Generated code writes
//!
//!     const rt = @import("runtime");
//!
//! and may use only what is re-exported here. Keeping this list short is what
//! lets the runtime be rewritten without touching the code generator.

const std = @import("std");

const value = @import("value.zig");
const apply_mod = @import("apply.zig");
const curry_mod = @import("curry.zig");

pub const Value = value.Value;
pub const Field = value.Field;
pub const Data = value.Data;
pub const Closure = value.Closure;
pub const Fn1 = value.Fn1;
pub const no_env = value.no_env;

pub const init = apply_mod.init;
pub const alloc = apply_mod.alloc;
pub const io = apply_mod.io;
pub const apply = apply_mod.apply;
pub const apply2 = apply_mod.apply2;
pub const apply3 = apply_mod.apply3;
pub const runEffect = apply_mod.runEffect;
pub const copyValues = apply_mod.copyValues;
pub const copyFields = apply_mod.copyFields;
pub const updateRecord = apply_mod.updateRecord;
pub const curry = curry_mod.curry;
pub const effect = curry_mod.effect;
pub const concatString = apply_mod.concatString;
pub const writeLine = apply_mod.writeLine;

test {
    _ = value;
    _ = apply_mod;
    _ = curry_mod;
}
