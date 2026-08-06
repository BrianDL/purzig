// HAND-WRITTEN TARGET, paired with Main.zig. See docs/codegen.md.
//
// Zig.Prelude's value declarations are all `foreign import`, so the generated
// module is re-exports plus the ordinary codegen for its one data type.
//
// Foreign re-exports are NULLARY FUNCTIONS, not constants, so that every
// top-level reference the emitter produces looks the same -- @"ps.f"() --
// whether it is foreign or generated.

const rt = @import("runtime");
const ffi = @import("ffi");

pub fn @"ps.concatString"() rt.Value {
    return ffi.@"Zig.Prelude".@"ps.concatString";
}

pub fn @"ps.log"() rt.Value {
    return ffi.@"Zig.Prelude".@"ps.log";
}

pub fn @"ps.pureUnit"() rt.Value {
    return ffi.@"Zig.Prelude".@"ps.pureUnit";
}

pub fn @"ps.Unit"() rt.Value {
    return rt.Value.mkData("Unit", &.{});
}

pub fn @"ps.unit"() rt.Value {
    return @"ps.Unit"();
}
