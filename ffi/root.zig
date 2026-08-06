//! Aggregates every FFI implementation into one module.
//!
//! Keyed by PURESCRIPT MODULE NAME, because that is all the emitter knows at a
//! use site -- CoreFn carries no package information. Where the Zig file lives
//! on disk is this file's business alone.

pub const @"Zig.Prelude" = @import("zig-prelude/prim.zig");
