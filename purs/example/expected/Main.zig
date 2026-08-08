// HAND-WRITTEN TARGET. This is what the emitter must eventually produce for
// purs/example/src/Main.purs. It is checked in so that:
//
//   1. the runtime API is validated by a real consumer before any codegen
//      exists -- `zig build run-expected` compiles and runs this today;
//   2. `Zig/Emit.purs` has a concrete artifact to aim at rather than a
//      description;
//   3. it can later become a golden file the emitter is diffed against.
//
// Source it corresponds to:
//
//     module Main where
//     import Zig.Prelude (Effect, Unit, concatString, log)
//     greet :: String -> String
//     greet name = concatString "Hello, " name
//     main :: Effect Unit
//     main = log (greet "Zig")
//
// See docs/codegen.md for the naming and emission rules used here.

const std = @import("std");
const rt = @import("runtime");

const @"mod.Zig.Prelude" = @import("Zig.Prelude.zig");

// greet = Abs "name" (App (App (Var Zig.Prelude.concatString) (Lit "Hello, ")) (Var "name"))
//
// Every top-level binding becomes a NULLARY function rather than a constant,
// because `rt.apply` allocates and a `const` would have to be comptime-known.
// Recomputing on each reference is semantically free -- PureScript is pure --
// and it sidesteps module initialisation order entirely. purerl uses the same
// convention.

fn @"ps.greet.lam0"(env: []const rt.Value, @"v.name": rt.Value) rt.Value {
    _ = env; // captures nothing: `concatString` is top-level, not free
    return rt.apply(
        rt.apply(@"mod.Zig.Prelude".@"ps.concatString", rt.Value.mkString("Hello, ")),
        @"v.name",
    );
}

pub fn @"ps.greet"() rt.Value {
    return rt.Value.mkClosure(@"ps.greet.lam0", rt.no_env);
}

// main = App (Var Zig.Prelude.log) (App (Var Main.greet) (Lit "Zig"))

pub fn @"ps.main"() rt.Value {
    return rt.apply(
        @"mod.Zig.Prelude".@"ps.log",
        rt.apply(@"ps.greet"(), rt.Value.mkString("Zig")),
    );
}

// Entry point. Emitted only for the module the build is rooted at.
//
// `std.process.Init` is Zig 0.16's "juicy main": it hands over an `Io` and an
// arena documented as permanent storage for the process, cleaned automatically
// on exit. That arena is precisely this backend's allocation strategy, so the
// runtime borrows both rather than constructing its own.

pub fn main(init: std.process.Init) !void {
    rt.init(init.io, init.arena.allocator());
    _ = rt.runEffect(@"ps.main"());
}
