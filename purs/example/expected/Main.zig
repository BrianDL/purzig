// HAND-WRITTEN TARGET. What the emitter must produce for
// purs/example/src/Main.purs. Buildable today via `zig build run-expected`,
// which is what validates the runtime API before codegen exists.
//
//     greet name = concatString "Hello, " name
//     main = log (greet "Zig")

const std = @import("std");
const rt = @import("runtime");

const @"mod.Zig.Prelude" = @import("Zig.Prelude.zig");

fn @"ps.greet.lam0"(env: []const rt.Value, @"v.name": rt.Value) rt.Value {
    _ = env;
    return rt.apply(rt.apply(@"mod.Zig.Prelude".@"ps.concatString"(), rt.Value.mkString("Hello, ")), @"v.name");
}

pub fn @"ps.greet"() rt.Value {
    return rt.Value.mkClosure(@"ps.greet.lam0", rt.no_env);
}

pub fn @"ps.main"() rt.Value {
    return rt.apply(@"mod.Zig.Prelude".@"ps.log"(), rt.apply(@"ps.greet"(), rt.Value.mkString("Zig")));
}

pub fn main(init: std.process.Init) !void {
    rt.init(init.io, init.arena.allocator());
    _ = rt.runEffect(@"ps.main"());
}
