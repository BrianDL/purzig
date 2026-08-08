//! FFI for Record.Unsafe.
//!
//! These differ from `rt.updateRecord` in one important way: `unsafeSet` ADDS
//! a field that is not already present, whereas record-update syntax is
//! type-checked and `updateRecord` panics on a missing key. This is the
//! machinery `Record.insert` and friends are built from, so adding is the
//! whole point.

const rt = @import("runtime");
const Value = rt.Value;
const Field = rt.Field;

fn find(fields: []const Field, label: []const u8) ?usize {
    for (fields, 0..) |f, i| {
        if (f.name.len == label.len and rt.Value.mkString(f.name).stringEq(label)) return i;
    }
    return null;
}

fn unsafeHas(label: Value, rec: Value) Value {
    return Value.mkBool(find(rec.asRecord(), label.asString()) != null);
}

fn unsafeGet(label: Value, rec: Value) Value {
    return rec.field(label.asString());
}

fn unsafeSet(label: Value, v: Value, rec: Value) Value {
    const fields = rec.asRecord();
    const name = label.asString();

    if (find(fields, name)) |i| {
        const out = rt.alloc().alloc(Field, fields.len) catch @panic("runtime: out of memory");
        @memcpy(out, fields);
        out[i] = .{ .name = name, .value = v };
        return Value.mkRecord(out);
    }

    const out = rt.alloc().alloc(Field, fields.len + 1) catch @panic("runtime: out of memory");
    @memcpy(out[0..fields.len], fields);
    out[fields.len] = .{ .name = name, .value = v };
    return Value.mkRecord(out);
}

fn unsafeDelete(label: Value, rec: Value) Value {
    const fields = rec.asRecord();
    const name = label.asString();

    const i = find(fields, name) orelse return rec;

    const out = rt.alloc().alloc(Field, fields.len - 1) catch @panic("runtime: out of memory");
    @memcpy(out[0..i], fields[0..i]);
    @memcpy(out[i..], fields[i + 1 ..]);
    return Value.mkRecord(out);
}

pub const @"ps.unsafeHas" = rt.curry(unsafeHas);
pub const @"ps.unsafeGet" = rt.curry(unsafeGet);
pub const @"ps.unsafeSet" = rt.curry(unsafeSet);
pub const @"ps.unsafeDelete" = rt.curry(unsafeDelete);
