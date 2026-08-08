// HAND-WRITTEN TARGET, paired with Main.zig. See docs/codegen.md.
//
// Zig.Prelude has no value declarations of its own -- every export is a
// `foreign import` -- so the generated module is nothing but re-exports from
// the FFI module. This is the entire foreign-import resolution rule:
//
//     foreign import f   in package P, module ...M
//       =>  pub const @"ps.f" = ffi.<P_underscored>.<m_lowercased>.@"ps.f";
//
// Keeping the indirection here rather than at use sites means generated code
// never mentions `ffi`, and a package can move its Zig implementation around
// without the emitter caring.

const ffi = @import("ffi");

pub const @"ps.concatString" = ffi.zig_prelude.prim.@"ps.concatString";
pub const @"ps.log" = ffi.zig_prelude.prim.@"ps.log";
pub const @"ps.pureUnit" = ffi.zig_prelude.prim.@"ps.pureUnit";

// `Unit` is an ordinary PureScript data type, so it gets ordinary codegen:
// a nullary constructor is a `data` Value with no fields.

pub fn @"ps.Unit"() rt.Value {
    return rt.Value.mkData("Unit", &.{});
}

pub fn @"ps.unit"() rt.Value {
    return @"ps.Unit"();
}

const rt = @import("runtime");
