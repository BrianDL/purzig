//! Zig side of `Effect/Console.purs`, transcribed from `Effect/Console.js` at
//! tag v6.1.0.
//!
//! `Effect.Console` is a thin wrapper over the browser/Node `console` object,
//! and several of its members describe features a native binary simply does not
//! have. Where a faithful equivalent exists it is used; where it does not, the
//! function is a no-op rather than a panic, because these are all diagnostics
//! and a program that calls `group` should not die for it.
//!
//! Divergences from the JavaScript backend, all deliberate:
//!
//!   * `log`, `info` and `debug` all write a line to stdout. Node routes
//!     `debug` to stdout too, so only the ability to filter by level is lost.
//!   * `warn` and `error` write to stderr, matching Node.
//!   * `time`, `timeLog` and `timeEnd` are no-ops. Implementing them needs a
//!     label-to-timestamp table and a clock, and Zig 0.16 routes clock access
//!     through `Io` -- worth doing if anyone wants it, not worth guessing at
//!     now.
//!   * `group` and `groupCollapsed` are no-ops, and so is `groupEnd`. Node uses
//!     them to indent subsequent output, which would mean threading an indent
//!     level through `rt.writeLine`.
//!   * `clear` is a no-op. Emitting an ANSI clear would corrupt piped output,
//!     and this backend's programs are as likely to be piped as watched.

const rt = @import("runtime");
const Value = rt.Value;

// -- stdout -----------------------------------------------------------------

fn log(msg: Value) Value {
    rt.writeLine(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.log" = rt.effect(log);

fn info(msg: Value) Value {
    rt.writeLine(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.info" = rt.effect(info);

fn debug(msg: Value) Value {
    rt.writeLine(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.debug" = rt.effect(debug);

// -- stderr -----------------------------------------------------------------

fn warn(msg: Value) Value {
    rt.writeLineErr(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.warn" = rt.effect(warn);

// Named `errorImpl` because `error` is a Zig keyword.
fn errorImpl(msg: Value) Value {
    rt.writeLineErr(msg.asString());
    return Value.mkUnit();
}

pub const @"ps.error" = rt.effect(errorImpl);

// -- no-ops -----------------------------------------------------------------
// The argument is taken and discarded so the signature still matches the
// PureScript type; `rt.effect` derives arity from it.

fn time(label: Value) Value {
    _ = label;
    return Value.mkUnit();
}

pub const @"ps.time" = rt.effect(time);

fn timeLog(label: Value) Value {
    _ = label;
    return Value.mkUnit();
}

pub const @"ps.timeLog" = rt.effect(timeLog);

fn timeEnd(label: Value) Value {
    _ = label;
    return Value.mkUnit();
}

pub const @"ps.timeEnd" = rt.effect(timeEnd);

fn group(label: Value) Value {
    _ = label;
    return Value.mkUnit();
}

pub const @"ps.group" = rt.effect(group);

fn groupCollapsed(label: Value) Value {
    _ = label;
    return Value.mkUnit();
}

pub const @"ps.groupCollapsed" = rt.effect(groupCollapsed);

// `groupEnd` and `clear` take no arguments in PureScript -- they are
// `Effect Unit` outright. `rt.effect` handles a nullary function by supplying
// only the unit thunk.

fn groupEnd() Value {
    return Value.mkUnit();
}

pub const @"ps.groupEnd" = rt.effect(groupEnd);

fn clear() Value {
    return Value.mkUnit();
}

pub const @"ps.clear" = rt.effect(clear);
