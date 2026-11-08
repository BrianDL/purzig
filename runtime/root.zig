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
const lazy_mod = @import("lazy.zig");
const marray_mod = @import("marray.zig");

pub const Value = value.Value;
pub const Field = value.Field;
pub const Data = value.Data;
pub const Closure = value.Closure;
pub const Fn1 = value.Fn1;
pub const no_env = value.no_env;
pub const Error = value.Error;

/// `true` when the runtime is compiled for a target with no OS underneath it
/// (`wasm32-freestanding`): no process, no `std.Io`, no console. Re-exported so
/// the generated driver can pick its entry point at comptime.
pub const freestanding = apply_mod.freestanding;

/// The type of Zig's `main` parameter on a native target (`std.process.Init`),
/// `void` on a freestanding one. The driver spells its parameter
/// `rt.ProcessInit`, which keeps `std.process` out of the generated sources.
pub const ProcessInit = apply_mod.ProcessInit;

/// Native only: takes the `Io` and the process arena from `std.process.Init`.
/// Referencing it on a freestanding target is a compile error.
pub const init = apply_mod.init;

/// Every target: the allocator, supplied by the caller. This is the whole
/// freestanding entry, where no process exists to hand one in.
pub const initAlloc = apply_mod.initAlloc;
pub const alloc = apply_mod.alloc;
pub const io = apply_mod.io;
pub const apply = apply_mod.apply;
pub const apply2 = apply_mod.apply2;
pub const apply3 = apply_mod.apply3;
pub const applyN = apply_mod.applyN;
pub const runEffect = apply_mod.runEffect;
pub const copyValues = apply_mod.copyValues;
pub const copyFields = apply_mod.copyFields;
pub const updateRecord = apply_mod.updateRecord;
pub const curry = curry_mod.curry;
pub const effect = curry_mod.effect;
pub const concatString = apply_mod.concatString;
pub const writeLine = apply_mod.writeLine;
pub const writeLineErr = apply_mod.writeLineErr;
pub const throwValue = apply_mod.throwValue;
pub const takeError = apply_mod.takeError;
pub const newRef = apply_mod.newRef;
pub const newLazy = lazy_mod.newLazy;
pub const setLazyInit = lazy_mod.setLazyInit;
pub const forceLazy = lazy_mod.forceLazy;
pub const newMutArray = marray_mod.newMutArray;

/// The bytes call path: `abi.Status`, `abi.Reply`, and the functions that cross
/// from bytes to a compiled module and back -- `abi.call`/`abi.callBytes` for
/// text (`String` arguments), `abi.callRaw` for bytes (no UTF-8 step anywhere).
/// The one module of the surface rather than a re-exported declaration, so the
/// contract stays fixed while everything above may be rewritten.
pub const abi = @import("abi.zig");

/// The canonical byte form of `Value`: `version`, `MAX_DEPTH`, `Error`, the
/// `tag` table, `Writer`/`Reader`, `encode`, `encodeTo` and `decode`. A property
/// of the value representation rather than of any one consumer, so it is a
/// module of the surface: a host that has to hand a `Value` to a compiled
/// program, or read one back, needs nothing else. Pure Zig with an
/// allocator passed in -- no `std.Io`, no process -- so it also compiles
/// unchanged on a freestanding target.
pub const valuecodec = @import("valuecodec.zig");

test {
    _ = value;
    _ = valuecodec;
    _ = apply_mod;
    _ = curry_mod;
    _ = lazy_mod;
    _ = marray_mod;
    _ = abi;
}
