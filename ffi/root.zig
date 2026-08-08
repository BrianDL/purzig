//! Aggregates every FFI implementation into one module.
//!
//! Generated code never imports this directly. Instead, the generated module
//! for a PureScript module containing `foreign import`s re-exports from here,
//! which keeps the foreign-import resolution rule in one place.

pub const zig_prelude = struct {
    pub const prim = @import("zig-prelude/prim.zig");
};
