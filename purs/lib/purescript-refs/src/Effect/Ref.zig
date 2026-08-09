//! Zig side of `Effect/Ref.purs`, transcribed from `Effect/Ref.js` at tag
//! v6.0.0.
//!
//! JavaScript represents a `Ref` as an object `{ value: ... }` and mutates it
//! in place. Every other `Value` variant in this runtime is immutable --
//! `updateRecord` is explicitly copy-on-write -- so a one-field record could
//! not work here: `mkRecord` copies, and a write would update a copy nobody
//! holds a reference to. Hence the dedicated `ref: *Value` variant, whose
//! indirection is what makes a write observable through every copy of the
//! reference.
//!
//! Note the arena never frees, so an overwritten value is retained for the life
//! of the process. A `Ref` written in a loop therefore costs memory
//! proportional to the number of writes, not to the size of what it holds.

const rt = @import("runtime");
const Value = rt.Value;
const Error = rt.Error;

// -- _new :: forall s. s -> Effect (Ref s) ----------------------------------

fn _new(val: Value) Value {
    return rt.newRef(val);
}

pub const @"ps._new" = rt.effect(_new);

// -- newWithSelf :: forall s. (Ref s -> s) -> Effect (Ref s) ----------------
//
// The reference has to exist before its contents do, so this allocates the cell
// directly rather than going through `rt.newRef`. JS does the same thing with
// `{ value: null }` followed by an assignment; unit stands in for null.

fn newWithSelf(f: Value) Error!Value {
    const cell = rt.alloc().create(Value) catch @panic("runtime: out of memory");
    cell.* = Value.mkUnit();
    const self = Value.mkRef(cell);
    cell.* = try rt.apply(f, self);
    return self;
}

pub const @"ps.newWithSelf" = rt.effect(newWithSelf);

// -- read :: forall s. Ref s -> Effect s ------------------------------------

fn read(ref: Value) Value {
    return ref.asRef().*;
}

pub const @"ps.read" = rt.effect(read);

// -- modifyImpl -------------------------------------------------------------
// `forall s b. (s -> { state :: s, value :: b }) -> Ref s -> Effect b`
//
// One call to `f` produces both the new state and the returned value; `modify`
// and `modify_` are defined in PureScript on top of this.

fn modifyImpl(f: Value, ref: Value) Error!Value {
    const cell = ref.asRef();
    const t = try rt.apply(f, cell.*);
    cell.* = t.field("state");
    return t.field("value");
}

pub const @"ps.modifyImpl" = rt.effect(modifyImpl);

// -- write :: forall s. s -> Ref s -> Effect Unit ---------------------------

fn write(val: Value, ref: Value) Value {
    ref.asRef().* = val;
    return Value.mkUnit();
}

pub const @"ps.write" = rt.effect(write);
