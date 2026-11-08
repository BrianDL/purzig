//! The canonical byte form of `Value` — the one wire format between a host and
//! the exports of a program purzig compiled. It is a property of
//! `runtime/value.zig`'s `Value`, so it lives beside it: any consumer that has
//! to hand a `Value` to a program, or read one back, needs this file and the tag
//! layout it names, and nothing else.
//!
//! WHY A CODEC AND NOT `rt.abi`: `rt.abi.call` is String-only — it turns every
//! input into `Value.mkString` and answers `Status.failed` for any result that
//! is not a `.string` (`runtime/abi.zig`). A program's state is not a string:
//! it is whatever PureScript type the consumer wrote, which at runtime is any
//! `Value` variant. `rt.apply` accepts any `Value`, so the ABI root builds
//! structured arguments itself and this file is how those arguments are turned
//! into the byte blobs a host hands over.
//!
//! THE PROPERTIES THAT MAKE IT A FORMAT rather than a serialisation:
//!
//!   * CANONICAL. `record` fields are written in ascending byte order of their
//!     NAMES, whatever order the `Value` holds them in. Two records that differ
//!     only in field order produce identical bytes, always: a summary's bytes
//!     are compared, hashed and used as an identity by a host, so "equal value"
//!     has to mean "equal bytes" or nothing downstream can rely on it. The
//!     consequence in the other direction is deliberate and is NOT a bug: a
//!     decoded record's fields are in THAT order, not in the order the caller
//!     held them, because a record is its name → value mapping and the slice
//!     order is the one part of a record this format does not preserve.
//!   * TAGGED, with the tag bytes numbered explicitly below. The numbers are
//!     the format; renumbering them is a wire change, and a wire change means a
//!     version bump (see the rule below).
//!   * BOUNDED. Nothing nests deeper than `MAX_DEPTH`. `decode` runs on bytes a
//!     host supplied, and under `ReleaseSmall` on wasm32 a stack overflow is
//!     memory corruption, not a trap — so hostile input must be refused before
//!     the stack grows, not after.
//!   * ALLOCATOR PASSED IN, never `rt.alloc()`. Host tests pass
//!     `std.testing.allocator`; a program passes its own bump arena. The
//!     runtime's allocator only exists after `rt.initAlloc`, and a codec that
//!     reaches for it cannot be unit-tested without a runtime.
//!
//! NOT ENCODABLE: `closure`, `ref` and `marray`. A closure has no byte form at
//! all. The two mutable variants have one, but it would be a snapshot of
//! something whose IDENTITY is the point — a decoded copy of a `Ref` is a
//! different `Ref`, and a host that round-tripped one would silently break the
//! aliasing the original relied on. `encode` answers `error.Unencodable`;
//! `decode` refuses the three reserved tags for the same reason.
//!
//! WHAT "EQUAL VALUES ENCODE EQUALLY" DOES NOT COVER, deliberately:
//!
//!   * `number` is written as its IEEE-754 bit pattern (little-endian), so
//!     `0.0` and `-0.0` differ and two `NaN`s with different payloads differ.
//!     Canonicalising those would mean inventing an equality PureScript does
//!     not have (`0.0 == -0.0` is `true` there) and would silently change a
//!     value a program computed.
//!   * duplicate field names are emitted in their original relative order (the
//!     sort is stable). Compiled PureScript records cannot have them, so this
//!     is a caller bug rather than a case to define.
//!
//! VERSIONED, from byte 0: `encode` writes `version` and then the value, so a
//! buffer says which ERA of this format produced it before it says anything
//! else. These bytes are a permanent commitment — state lives on peers nobody
//! here controls, a summary's bytes are compared by the host, and a format
//! change after deployment would be a migration of live state — so the byte is
//! here NOW, while no live state exists: free today, expensive later.
//!
//! THE RULE, in two halves:
//!
//!   * A BUMP IS REQUIRED for any change to tag NUMBERING (`0x03` stops meaning
//!     `number`), to field ORDERING (a record's ascending-name order, or the
//!     tag/length/fields sequence inside `data`), to container FRAMING (a length
//!     or count changing width or position), or to the MEANING of an existing
//!     tag (`integer` gaining a unit, `char` becoming a byte index). Each of
//!     those changes what an old peer's bytes MEAN, so a v1 buffer read under the
//!     new rules would decode to a different value or to nothing — the one thing
//!     a version byte exists to prevent.
//!   * A BUMP IS NOT REQUIRED for a NEW tag with a NEW number, i.e. a new
//!     `Value` shape: no v1 byte stream can contain it, so every v1 buffer still
//!     decodes exactly as it did. A v1-era decoder meeting it answers
//!     `error.UnknownTag` — a rejection of bytes it never claimed to read, which
//!     is the correct answer rather than a misreading. (If the new shape needs an
//!     EXISTING tag to mean something else, that is the first case, not this
//!     one.)
//!
//! An unknown version is REJECTED, never guessed: `decode` answers
//! `error.UnsupportedVersion` for any byte 0 other than `version`, and there is
//! deliberately no "try v1, then v2" fallback. Guessing is how a v2 buffer that
//! happens to start with a v1-shaped tag would become v1 state on a peer that
//! cannot know better; the distinct error is what makes a future v2 arriving at
//! this module DIAGNOSABLE instead of indistinguishable from corruption.
//!
//! An EMPTY buffer is untouched by all of this: it is still `error.Truncated` at
//! this layer, because "no bytes" means a fresh instance only ABOVE the codec,
//! in the ABI root — the codec is never asked to invent a value for nothing.

const std = @import("std");

// THE VALUE TYPE, from its SIBLING module `value.zig`, never by the module
// name a consumer uses: inside the runtime that name resolves to nothing (there
// is no self-import here -- `root.zig` is the file that RE-EXPORTS this one as
// `rt.valuecodec`). These are the same declarations `root.zig` publishes as
// `Value`, `Field` and `no_env`, bound locally so the codec reads as itself.
const value_module = @import("value.zig");

const Value = value_module.Value;
const Field = value_module.Field;
const no_env = value_module.no_env;

/// `rt.Error` in a consumer's spelling: the error set an `rt.Fn1` returns. NOT
/// this file's `Error` below, which is what the CODEC refuses with.
const RtError = value_module.Error;

/// The FORMAT VERSION: byte 0 of every buffer this file writes, and the first
/// byte it reads.
///
/// ONE named constant, referenced by BOTH `encode` and `decode`, so a bump is a
/// single edit and cannot drift into a writer and a reader that disagree. Bump
/// it for a change to tag numbering, field ordering, container framing or the
/// meaning of an existing tag — NEVER for a new tag with a new number. The rule
/// in full is in this file's module docs.
pub const version: u8 = 0x01;

/// The deepest nesting `encode` will write and `decode` will read.
///
/// 64 is generous for program state (records of scalars, arrays of records)
/// and small enough that the recursive descent cannot reach a wasm stack limit:
/// every level costs a few frames, and this whole file is compiled
/// `ReleaseSmall`, where Zig does not check for overflow.
pub const MAX_DEPTH: usize = 64;

/// Everything this codec can refuse. A caller that wants to distinguish "the
/// host sent garbage" from "this value cannot cross" matches on these.
pub const Error = error{
    /// Byte 0 was not `version`: these bytes came from another ERA of this
    /// format, so nothing after byte 0 has a meaning here.
    ///
    /// Deliberately distinct from `UnknownTag`, from `Truncated` and from every
    /// other refusal: a future v2 arriving at a v1 module must be diagnosable,
    /// not indistinguishable from corruption. The version is checked BEFORE the
    /// value, so a v2 buffer is never cited for a tag or a length it does not
    /// own.
    UnsupportedVersion,

    /// `closure`, `ref` or `marray`: no canonical byte form exists.
    Unencodable,

    /// The input ended in the middle of a tag, a length or a body.
    Truncated,

    /// A length or element count is larger than the bytes that remain, so it
    /// could not be satisfied even if every remaining byte belonged to it.
    OversizedLength,

    /// A tag byte this format does not define (and is not one of the three
    /// reserved-but-unencodable ones, which answer `Unencodable`).
    UnknownTag,

    /// A `boolean` byte other than 0 or 1.
    InvalidBoolean,

    /// A `char` code point above U+10FFFF.
    InvalidChar,

    /// More than `MAX_DEPTH` nested containers.
    DepthExceeded,

    /// A complete value, followed by bytes that belong to nothing.
    TrailingBytes,

    /// The caller's allocator refused. Never a panic: the root passes a bump
    /// arena and reports failure to the host as a refusal.
    OutOfMemory,
};

/// THE WIRE TAGS. Every byte below sits AFTER `version`, i.e. at byte 1 or
/// later; nothing in this table is ever byte 0 any more. These bytes are the
/// format — a comment is not enough, so they are named constants used by both
/// directions, and nothing writes a bare integer.
///
/// | byte | variant  | payload                                                    |
/// |------|----------|------------------------------------------------------------|
/// | 0x00 | unit     | —                                                          |
/// | 0x01 | boolean  | 1 byte: 0 or 1                                             |
/// | 0x02 | integer  | 4 bytes, little-endian i32 (two's complement)              |
/// | 0x03 | number   | 8 bytes, little-endian IEEE-754 binary64 bit pattern       |
/// | 0x04 | string   | u32 LE length, then that many bytes                        |
/// | 0x05 | char     | 4 bytes, little-endian u32 code point (≤ 0x10FFFF)         |
/// | 0x06 | array    | u32 LE count, then that many values                        |
/// | 0x07 | record   | u32 LE count, then per field: u32 LE name length, name     |
/// |      |          | bytes, value — fields in ascending name order              |
/// | 0x08 | data     | u32 LE tag-string length, tag STRING bytes, u32 LE field   |
/// |      |          | count, then that many values (positional)                  |
/// |------|----------|------------------------------------------------------------|
/// | 0x09 | closure  | reserved — NEVER on the wire, `Unencodable` both ways       |
/// | 0x0a | ref      | reserved — NEVER on the wire                               |
/// | 0x0b | marray   | reserved — NEVER on the wire                               |
///
/// `data` writes its TAG STRING, not a positional index: the compiler's
/// `CtorMeta` carries an integer tag, but the runtime's `Data` carries the
/// constructor NAME (`Value.mkData("Just", ...)`, `docs/codegen.md`), and a
/// wire format that numbered them would break the first time a consumer added a
/// constructor to an existing module.
pub const tag = struct {
    pub const unit: u8 = 0x00;
    pub const boolean: u8 = 0x01;
    pub const integer: u8 = 0x02;
    pub const number: u8 = 0x03;
    pub const string: u8 = 0x04;
    pub const char: u8 = 0x05;
    pub const array: u8 = 0x06;
    pub const record: u8 = 0x07;
    pub const data: u8 = 0x08;

    /// Reserved: these three variants have no byte form, so these bytes must
    /// never appear in a buffer. `decode` reports them as `Unencodable` rather
    /// than as an unknown tag, because the reason is different and a caller may
    /// care.
    pub const closure: u8 = 0x09;
    pub const ref: u8 = 0x0a;
    pub const marray: u8 = 0x0b;
};

/// Where `encode` puts bytes: an allocator-owned, growable byte buffer.
///
/// Deliberately a concrete type rather than `anytype` and rather than a
/// `std.Io.Writer`: this file must be analysable on `wasm32-freestanding`,
/// where the runtime's own `std.Io` names are `@compileError`s
/// (`runtime/apply.zig`), and a generic writer would put the caller's error set
/// into this file's signature. `std.ArrayList(u8)` is allocator-based and needs
/// no OS, and `Writer.deinit` exists for host tests — the program's root
/// deliberately never calls it, because the bytes it produced are handed to the
/// host and must outlive the call.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.gpa);
    }

    /// The bytes written so far. Valid until the next `encode` into this
    /// writer, and owned by whoever owns `gpa`.
    pub fn bytes(self: *const Writer) []const u8 {
        return self.buf.items;
    }
};

/// Where `decode` reads bytes from: the whole input plus a cursor.
///
/// The cursor is private in spirit — callers only construct one and hand it to
/// `decode` — so that every read goes through the checked helpers below and
/// there is exactly one place (`take`) where a length becomes a slice.
pub const Reader = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn init(input: []const u8) Reader {
        return .{ .input = input };
    }

    /// Bytes not yet consumed. Used by the length checks; never negative,
    /// because `pos` only advances past bytes that were checked to exist.
    pub fn remaining(self: *const Reader) usize {
        if (self.pos >= self.input.len) return 0;
        return self.input.len - self.pos;
    }
};

// --- encode ----------------------------------------------------------------

/// Encode one value into `w`, using `gpa` for the scratch a canonical record
/// needs (a sorted copy of the field slice).
///
/// Two allocators, one purpose each: `w.gpa` grows the output buffer, `gpa` is
/// borrowed for the duration of the call only. They are normally the same
/// allocator; they are separate parameters because the issue's API says so and
/// because a host test may want the scratch to be the testing allocator while
/// the output lives in an arena.
pub fn encode(w: *Writer, gpa: std.mem.Allocator, value: Value) Error!void {
    // Byte 0 of EVERY buffer, then the value exactly as it was encoded before
    // the prefix existed. The prefix is a header, not a redesign: not one tag,
    // length or field order below this line changed.
    const start = w.buf.items.len;
    try putByte(w, version);

    encodeAt(w, gpa, value, 0) catch |err| {
        // A refusal leaves the writer exactly as it found it. A version byte
        // announcing a value that was never written would be worse than no
        // bytes at all: the reader would trust a header with nothing behind it.
        w.buf.items.len = start;
        return err;
    };
}

/// Encode into a fresh buffer and hand it back. Convenience for hosts and
/// tests; a program's root uses `encode` directly so it also knows the buffer
/// is the last allocation in its arena.
pub fn encodeTo(gpa: std.mem.Allocator, value: Value) Error![]const u8 {
    var w = Writer.init(gpa);
    try encode(&w, gpa, value);
    return w.bytes();
}

fn encodeAt(w: *Writer, gpa: std.mem.Allocator, value: Value, depth: usize) Error!void {
    // `depth` is how many containers already enclose this value, so a value
    // inside MAX_DEPTH containers is fine and the (MAX_DEPTH + 1)-th container's
    // contents are not.
    if (depth > MAX_DEPTH) return error.DepthExceeded;

    switch (value) {
        .unit => try putByte(w, tag.unit),
        .boolean => |b| {
            try putByte(w, tag.boolean);
            try putByte(w, if (b) 1 else 0);
        },
        .integer => |i| {
            try putByte(w, tag.integer);
            const bits: u32 = @bitCast(i);
            try putU32(w, bits);
        },
        .number => |n| {
            try putByte(w, tag.number);
            const bits: u64 = @bitCast(n);
            try putU32(w, @truncate(bits));
            try putU32(w, @truncate(bits >> 32));
        },
        .string => |s| {
            try putByte(w, tag.string);
            try putLen(w, s.len);
            try putBytes(w, s);
        },
        .char => |c| {
            try putByte(w, tag.char);
            try putU32(w, @as(u32, c));
        },
        .array => |items| {
            try putByte(w, tag.array);
            try putLen(w, items.len);
            for (items) |item| try encodeAt(w, gpa, item, depth + 1);
        },
        .record => |fields| {
            // Count first, then the fields in NAME order. The count is written
            // before the sort, so an ordering bug can never change the framing.
            try putByte(w, tag.record);
            try putLen(w, fields.len);
            try encodeFields(w, gpa, fields, depth);
        },
        .data => |d| {
            try putByte(w, tag.data);
            try putLen(w, d.tag.len);
            try putBytes(w, d.tag);
            try putLen(w, d.fields.len);
            for (d.fields) |field| try encodeAt(w, gpa, field, depth + 1);
        },

        // No byte form exists, and a snapshot of a mutable cell would be a
        // different value. See the module docs.
        .closure, .ref, .marray => return error.Unencodable,
    }
}

/// A record's fields, sorted by name, each written as name-then-value.
///
/// The sort is over a COPY: `Value.record` is a `[]const Field` the caller
/// owns and may reuse, so reordering it in place would be a side effect on a
/// value that `Value` semantics say is immutable. Insertion sort because field
/// counts are single digits and a stable order is easier to reason about than a
/// pattern-defeating quicksort's.
fn encodeFields(w: *Writer, gpa: std.mem.Allocator, fields: []const Field, depth: usize) Error!void {
    if (fields.len == 0) return;

    const sorted = gpa.alloc(Field, fields.len) catch return error.OutOfMemory;
    defer gpa.free(sorted);
    @memcpy(sorted, fields);
    sortFieldsByName(sorted);

    for (sorted) |field| {
        try putLen(w, field.name.len);
        try putBytes(w, field.name);
        try encodeAt(w, gpa, field.value, depth + 1);
    }
}

fn sortFieldsByName(fields: []Field) void {
    var i: usize = 1;
    while (i < fields.len) : (i += 1) {
        const moving = fields[i];
        var j: usize = i;
        while (j > 0 and std.mem.order(u8, moving.name, fields[j - 1].name) == .lt) : (j -= 1) {
            fields[j] = fields[j - 1];
        }
        fields[j] = moving;
    }
}

fn putByte(w: *Writer, byte: u8) Error!void {
    w.buf.append(w.gpa, byte) catch return error.OutOfMemory;
}

fn putBytes(w: *Writer, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;
    w.buf.appendSlice(w.gpa, bytes) catch return error.OutOfMemory;
}

/// Little-endian u32, byte by byte.
///
/// Spelled out rather than `std.mem.readInt`/`writeInt`: the wire format is the
/// contract and this is the only place the byte order is decided, so it is
/// worth being able to read it without knowing which slice-pointer spelling of
/// `readInt` this Zig version wants.
fn putU32(w: *Writer, value: u32) Error!void {
    try putByte(w, @truncate(value));
    try putByte(w, @truncate(value >> 8));
    try putByte(w, @truncate(value >> 16));
    try putByte(w, @truncate(value >> 24));
}

/// A length or count, refusing anything that would not fit the wire's u32.
fn putLen(w: *Writer, len: usize) Error!void {
    if (len > std.math.maxInt(u32)) return error.OversizedLength;
    try putU32(w, @intCast(len));
}

// --- decode ----------------------------------------------------------------

/// Decode exactly one value from `r`, allocating everything it produces from
/// `gpa`.
///
/// All or nothing about the BUFFER: a complete value followed by anything else
/// is `error.TrailingBytes`, so a host cannot smuggle a second value past a
/// reader and a callee cannot silently ignore half its input.
///
/// Not all or nothing about MEMORY: a refusal part-way through leaves whatever
/// it had already allocated with the caller. Both callers (the root's bump
/// arena, a test's arena) never free individual values, so unwinding would buy
/// nothing; a caller with a real allocator that cares should pass an arena.
pub fn decode(r: *Reader, gpa: std.mem.Allocator) Error!Value {
    // Byte 0 says which ERA wrote the rest, and it is answered FIRST. Reading a
    // tag before the version would let `decodeAt` report `UnknownTag`,
    // `InvalidBoolean` or `OversizedLength` about bytes whose meaning it never
    // knew — which is exactly the confusion the version byte exists to remove.
    // There is no fallback that tries v1 and then v2: an unknown version is
    // rejected, not guessed.
    if (try takeByte(r) != version) return error.UnsupportedVersion;

    const value = try decodeAt(r, gpa, 0);
    if (r.pos != r.input.len) return error.TrailingBytes;
    return value;
}

fn decodeAt(r: *Reader, gpa: std.mem.Allocator, depth: usize) Error!Value {
    if (depth > MAX_DEPTH) return error.DepthExceeded;

    const which = try takeByte(r);
    switch (which) {
        tag.unit => return Value.mkUnit(),

        tag.boolean => {
            const byte = try takeByte(r);
            if (byte > 1) return error.InvalidBoolean;
            return Value.mkBool(byte == 1);
        },

        tag.integer => {
            const bits = try takeU32(r);
            return Value.mkInt(@bitCast(bits));
        },

        tag.number => {
            const low: u64 = try takeU32(r);
            const high: u64 = try takeU32(r);
            return Value.mkNumber(@bitCast((high << 32) | low));
        },

        tag.string => {
            const len = try takeLen(r);
            const bytes = try take(r, len);
            return Value.mkString(try dupe(gpa, bytes));
        },

        tag.char => {
            const point = try takeU32(r);
            if (point > 0x10ffff) return error.InvalidChar;
            return Value.mkChar(@intCast(point));
        },

        tag.array => {
            const count = try takeCount(r);
            const items = gpa.alloc(Value, count) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < count) : (i += 1) items[i] = try decodeAt(r, gpa, depth + 1);
            return Value.mkArray(items);
        },

        tag.record => {
            const count = try takeCount(r);
            const fields = gpa.alloc(Field, count) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const name_len = try takeLen(r);
                const name = try dupe(gpa, try take(r, name_len));
                fields[i] = .{ .name = name, .value = try decodeAt(r, gpa, depth + 1) };
            }
            return Value.mkRecord(fields);
        },

        tag.data => {
            const name_len = try takeLen(r);
            const name = try dupe(gpa, try take(r, name_len));
            const count = try takeCount(r);
            const fields = gpa.alloc(Value, count) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < count) : (i += 1) fields[i] = try decodeAt(r, gpa, depth + 1);
            return Value.mkData(name, fields);
        },

        // Reserved: never emitted, never accepted.
        tag.closure, tag.ref, tag.marray => return error.Unencodable,

        else => return error.UnknownTag,
    }
}

fn takeByte(r: *Reader) Error!u8 {
    return (try take(r, 1))[0];
}

fn takeU32(r: *Reader) Error!u32 {
    const bytes = try take(r, 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// A byte LENGTH from the wire, checked against what is left before it is
/// trusted.
///
/// This is the check that makes hostile input cheap to refuse: without it, a
/// length of 0xFFFFFFFF would be turned into a slice and the first read would
/// walk off the end of linear memory.
fn takeLen(r: *Reader) Error!usize {
    const len = try takeU32(r);
    if (@as(usize, len) > r.remaining()) return error.OversizedLength;
    return @intCast(len);
}

/// An ELEMENT COUNT from the wire. Every element of every container costs at
/// least one byte (its tag), so a count larger than the bytes left cannot be
/// satisfied either — and checking it here means `gpa.alloc` is never asked for
/// a count derived from a hostile four-byte field.
fn takeCount(r: *Reader) Error!usize {
    const count = try takeU32(r);
    if (@as(usize, count) > r.remaining()) return error.OversizedLength;
    return @intCast(count);
}

/// `n` bytes from the front of the reader, or `error.Truncated`.
fn take(r: *Reader, n: usize) Error![]const u8 {
    // Defensive: `pos` cannot pass `input.len` through this function, but a
    // wrapped subtraction would make the check below vacuous, and this file is
    // compiled `ReleaseSmall` where wrapping is silent.
    if (r.pos > r.input.len) return error.Truncated;
    if (n > r.input.len - r.pos) return error.Truncated;

    const out = r.input[r.pos .. r.pos + n];
    r.pos += n;
    return out;
}

fn dupe(gpa: std.mem.Allocator, src: []const u8) Error![]const u8 {
    return gpa.dupe(u8, src) catch return error.OutOfMemory;
}

// --- tests -----------------------------------------------------------------
// Host tests only: `zig build test-valuecodec` compiles THIS file for the host,
// and `zig build test-runtime` runs the same tests through `root.zig`'s test
// block, so nothing here needs purs, spago, a wasm runtime or an `Io`.
//
// Every test takes its allocator from an `ArenaAllocator` over
// `std.testing.allocator`: decoding allocates a tree of values that the codec
// never frees on purpose (see `decode`), and the arena is also what the real
// caller passes, so the tests exercise the same allocation pattern.

fn arenaOf(parent: std.mem.Allocator) std.heap.ArenaAllocator {
    return .init(parent);
}

/// Which `Value` shape a value is, for the round-trip assertions.
///
/// A small enum rather than `std.meta.activeTag`: the switch in `shapeOf` is
/// EXHAUSTIVE over `Value`, so a shape added to the runtime becomes a compile
/// error here instead of a shape nobody round-trips.
const Shape = enum {
    unit,
    boolean,
    integer,
    number,
    string,
    char,
    array,
    record,
    data,
    /// `closure`, `ref` or `marray`: no byte form, so never round-tripped.
    unsupported,
};

fn shapeOf(value: Value) Shape {
    return switch (value) {
        .unit => .unit,
        .boolean => .boolean,
        .integer => .integer,
        .number => .number,
        .string => .string,
        .char => .char,
        .array => .array,
        .record => .record,
        .data => .data,
        .closure, .ref, .marray => .unsupported,
    };
}

/// `decode(encode(v))` must give back `v`, field for field — not merely a value
/// that re-encodes to the same bytes. A codec can be self-consistent and wrong;
/// this is the assertion that is about the VALUE.
///
/// A RECORD is compared in the format's OWN field order, not in whatever order
/// the fixture happens to hold: `encode` writes a record's fields in ascending
/// byte order of their NAMES (that is what makes two records differing only in
/// field order produce identical bytes, which a host comparing summaries
/// depends on), so `decode` hands a record back SORTED whatever order it arrived
/// in. A record is its name → value mapping; the order of the `Value` slice
/// is precisely the part of a record the format does not preserve. Comparing the
/// two slices positionally would therefore fail on a CORRECT codec for any
/// fixture that is not already sorted — `{ y, x }` comes back as `{ x, y }` — and
/// would pass only because every fixture happened to be sorted.
///
/// Both sides are sorted with `sortFieldsByName`, the SAME function `encode`
/// uses, so this comparison cannot drift from the order the wire is written in.
/// That sort is stable, so duplicate field names keep their relative order,
/// exactly as they do in the bytes (see the module docs).
///
/// Spelled out rather than `std.meta.eql` because a `Value` holds slices and a
/// `Data` holds a tag STRING: the interesting part is the CONTENT, and writing
/// the recursion out is what makes a wrong comparison a compile error when
/// `Value` changes.
fn expectSameValue(gpa: std.mem.Allocator, expected: Value, actual: Value) !void {
    try std.testing.expectEqual(shapeOf(expected), shapeOf(actual));

    switch (shapeOf(expected)) {
        .unit, .unsupported => {},
        .boolean => try std.testing.expectEqual(expected.boolean, actual.boolean),
        .integer => try std.testing.expectEqual(expected.integer, actual.integer),
        // The bit pattern IS the value (see the module docs): `0.0` and `-0.0`
        // differ, so this is not float `==`.
        .number => try std.testing.expectEqual(
            @as(u64, @bitCast(expected.number)),
            @as(u64, @bitCast(actual.number)),
        ),
        .string => try std.testing.expectEqualStrings(expected.string, actual.string),
        .char => try std.testing.expectEqual(expected.char, actual.char),
        .array => {
            const want = expected.array;
            const got = actual.array;
            try std.testing.expectEqual(want.len, got.len);
            for (want, got) |want_item, got_item| try expectSameValue(gpa, want_item, got_item);
        },
        .record => {
            const want = expected.record;
            const got = actual.record;
            try std.testing.expectEqual(want.len, got.len);

            // Copies, both sides: `Value.record` is a `[]const Field` the
            // caller owns and may reuse, so sorting in place would rewrite a
            // fixture. An empty record duplicates to an empty slice, which the
            // loop below handles like any other length.
            const want_sorted = try gpa.dupe(Field, want);
            defer gpa.free(want_sorted);
            const got_sorted = try gpa.dupe(Field, got);
            defer gpa.free(got_sorted);
            sortFieldsByName(want_sorted);
            sortFieldsByName(got_sorted);

            for (want_sorted, got_sorted) |want_field, got_field| {
                try std.testing.expectEqualStrings(want_field.name, got_field.name);
                try expectSameValue(gpa, want_field.value, got_field.value);
            }
        },
        .data => {
            const want = expected.data;
            const got = actual.data;
            try std.testing.expectEqualStrings(want.tag, got.tag);
            try std.testing.expectEqual(want.fields.len, got.fields.len);
            for (want.fields, got.fields) |want_item, got_item| try expectSameValue(gpa, want_item, got_item);
        },
    }
}

fn expectCanonical(gpa: std.mem.Allocator, value: Value) !void {
    const first = try encodeTo(gpa, value);
    var r = Reader.init(first);
    const decoded = try decode(&r, gpa);
    // Both properties, in one place: the VALUE survives the round trip, and the
    // bytes it produces are stable.
    try expectSameValue(gpa, value, decoded);
    const second = try encodeTo(gpa, decoded);
    try std.testing.expectEqualSlices(u8, first, second);
}

fn expectDecodeError(gpa: std.mem.Allocator, input: []const u8, want: Error) !void {
    var r = Reader.init(input);
    try std.testing.expectError(want, decode(&r, gpa));
}

fn ignoreBody(env: []const Value, argument: Value) RtError!Value {
    _ = env;
    return argument;
}

test "round trip: unit, boolean, integer (including negative), number, char, string, array, record, data" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Deliberately NOT in canonical order — `y` before `x` before `空` — because
    // that is the interesting case for a record: the format sorts by field NAME,
    // so this value round-trips as a name → value mapping, and `decode` answers
    // it in the wire's order. `expectSameValue` compares records in that order
    // (see its docs), so the assertion at the end of this test is what keeps the
    // sort itself from being assumed rather than checked.
    const fields = [_]Field{
        .{ .name = "y", .value = Value.mkInt(-2) },
        .{ .name = "x", .value = Value.mkBool(true) },
        .{ .name = "空", .value = Value.mkUnit() },
    };
    const payload = [_]Value{ Value.mkInt(7), Value.mkString("seven") };

    const cases = [_]Value{
        Value.mkUnit(),
        Value.mkBool(false),
        Value.mkBool(true),
        Value.mkInt(0),
        Value.mkInt(-1),
        Value.mkInt(-2147483648),
        Value.mkInt(2147483647),
        Value.mkNumber(1.5),
        Value.mkNumber(-0.25),
        Value.mkChar('q'),
        Value.mkString(""),
        Value.mkString("hello"),
        Value.mkArray(&.{}),
        Value.mkArray(&[_]Value{ Value.mkInt(1), Value.mkString("two") }),
        Value.mkRecord(&.{}),
        Value.mkRecord(&fields),
        Value.mkData("Nothing", &.{}),
        Value.mkData("Just", &payload),
    };

    for (cases) |case| try expectCanonical(gpa, case);

    // ...and the one record above that arrived unsorted comes back sorted, by
    // NAME: `x` < `y` < `空` in byte order. Without this, a codec that preserved
    // insertion order would still pass — and it would then produce different
    // bytes for two equal records.
    const record_bytes = try encodeTo(gpa, Value.mkRecord(&fields));
    var record_reader = Reader.init(record_bytes);
    const record_back = try decode(&record_reader, gpa);
    const back_fields = record_back.asRecord();
    try std.testing.expectEqual(@as(usize, 3), back_fields.len);
    try std.testing.expectEqualStrings("x", back_fields[0].name);
    try std.testing.expectEqualStrings("y", back_fields[1].name);
    try std.testing.expectEqualStrings("空", back_fields[2].name);
}

test "decode(encode v) equals v for every shape the codec supports" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const field = [_]Field{.{ .name = "count", .value = Value.mkInt(3) }};

    // ONE case per shape, in tag order. `expectSameValue` compares the VALUE;
    // `expectCanonical` above additionally compares the bytes on the way back
    // out, and both run here so neither property can regress silently.
    const shapes = [_]Value{
        Value.mkUnit(), // 0x00 unit
        Value.mkBool(true), // 0x01 boolean
        Value.mkInt(-2147483648), // 0x02 integer
        Value.mkNumber(-0.0), // 0x03 number
        Value.mkString("a string"), // 0x04 string
        Value.mkChar(0x10fffd), // 0x05 char
        Value.mkArray(&[_]Value{Value.mkInt(1)}), // 0x06 array
        Value.mkRecord(&field), // 0x07 record
        Value.mkData("Just", &[_]Value{Value.mkInt(3)}), // 0x08 data
    };

    for (shapes) |shape| {
        const bytes = try encodeTo(gpa, shape);
        // Byte 0 is the version, and it is byte 0 of EVERY buffer, whatever the
        // value behind it is.
        try std.testing.expectEqual(version, bytes[0]);

        var r = Reader.init(bytes);
        const decoded = try decode(&r, gpa);
        try expectSameValue(gpa, shape, decoded);
        try expectCanonical(gpa, shape);
    }
}

test "encode writes the version byte first, then the encoding unchanged" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // The prefix on its own: one byte, then the tag that was byte 0 before.
    const unit_bytes = try encodeTo(gpa, Value.mkUnit());
    try std.testing.expectEqualSlices(u8, &.{ version, tag.unit }, unit_bytes);

    // ...and the bytes AFTER the prefix are the old layout, byte for byte:
    // `0x02` (integer) then the i32 little-endian, now at offset 1.
    const integer_bytes = try encodeTo(gpa, Value.mkInt(-2));
    try std.testing.expectEqualSlices(u8, &.{ version, tag.integer, 0xfe, 0xff, 0xff, 0xff }, integer_bytes);

    // The prefix is EXACTLY one byte: a value that used to be n bytes is now
    // n + 1, so nothing else about the framing moved.
    try std.testing.expectEqual(@as(usize, 1 + 5), integer_bytes.len);
}

test "decode rejects an unknown version with UnsupportedVersion, not a generic error" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A future v2 buffer: byte 0 says 2, and the body would be a perfectly good
    // v1 unit. The answer must name the VERSION — this is the whole point of the
    // byte, and the assertion is that it is not `UnknownTag`, not `Truncated`
    // and not any other refusal.
    try expectDecodeError(gpa, &.{ 0x02, tag.unit }, error.UnsupportedVersion);

    // No body needed: `0x02` alone is a version mismatch, NOT a truncation.
    try expectDecodeError(gpa, &.{0x02}, error.UnsupportedVersion);

    // 0x00 was never a format either, so it is refused the same way rather than
    // being read as a unit tag (which `0x00` is, after the prefix).
    try expectDecodeError(gpa, &.{ 0x00, tag.unit }, error.UnsupportedVersion);

    // The version is decided BEFORE the value, so a v2 buffer is never cited for
    // a tag or a length it does not own: both of these would otherwise be
    // `UnknownTag` and `OversizedLength`.
    try expectDecodeError(gpa, &.{ 0x02, 0x0c }, error.UnsupportedVersion);
    try expectDecodeError(gpa, &.{ 0x02, tag.string, 0xff, 0xff, 0xff, 0xff }, error.UnsupportedVersion);

    // An empty buffer is unchanged by the prefix: the codec still reports
    // `Truncated`, and "no bytes" keeps meaning a fresh instance ABOVE this
    // layer, in the ABI root.
    try expectDecodeError(gpa, &.{}, error.Truncated);
}

test "two records whose fields are in a different order encode to identical bytes" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const inner_forward = [_]Field{
        .{ .name = "a", .value = Value.mkInt(1) },
        .{ .name = "b", .value = Value.mkInt(2) },
    };
    const inner_backward = [_]Field{
        .{ .name = "b", .value = Value.mkInt(2) },
        .{ .name = "a", .value = Value.mkInt(1) },
    };
    const forward = [_]Field{
        .{ .name = "alpha", .value = Value.mkInt(1) },
        .{ .name = "beta", .value = Value.mkRecord(&inner_forward) },
        .{ .name = "gamma", .value = Value.mkString("g") },
    };
    const backward = [_]Field{
        .{ .name = "gamma", .value = Value.mkString("g") },
        .{ .name = "beta", .value = Value.mkRecord(&inner_backward) },
        .{ .name = "alpha", .value = Value.mkInt(1) },
    };

    const first = try encodeTo(gpa, Value.mkRecord(&forward));
    const second = try encodeTo(gpa, Value.mkRecord(&backward));
    try std.testing.expectEqualSlices(u8, first, second);

    // ...and the sort is by NAME, not by insertion order, so the decoded record
    // really is in canonical order rather than merely re-encoding the same way.
    var r = Reader.init(first);
    const decoded = try decode(&r, gpa);
    const names = decoded.asRecord();
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("alpha", names[0].name);
    try std.testing.expectEqualStrings("beta", names[1].name);
    try std.testing.expectEqualStrings("gamma", names[2].name);
}

test "the data tag string is written, not a positional index" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bytes = try encodeTo(gpa, Value.mkData("Just", &.{Value.mkInt(3)}));
    // version, 0x08, u32 tag length, "Just", u32 field count, then the field.
    try std.testing.expectEqualSlices(u8, &.{
        version,
        tag.data,
        4, 0, 0, 0,
        'J', 'u', 's', 't',
        1, 0, 0, 0,
        tag.integer,
        3, 0, 0, 0,
    }, bytes);
}

test "closure, ref and marray are Unencodable" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var cell: Value = .unit;
    var list: std.ArrayList(Value) = .empty;
    const cases = [_]Value{
        Value.mkClosure(ignoreBody, no_env),
        Value.mkRef(&cell),
        Value.mkMutArray(&list),
    };

    for (cases) |case| {
        var w = Writer.init(gpa);
        defer w.deinit();
        try std.testing.expectError(error.Unencodable, encode(&w, gpa, case));

        // Nothing was written for the refusal: the version byte is rolled back
        // with the value, so a failed encode leaves the writer untouched.
        try std.testing.expectEqual(@as(usize, 0), w.bytes().len);
    }

    // The same holds part-way through a container: a refusal must not leave half
    // a value behind a version byte.
    var nested_writer = Writer.init(gpa);
    defer nested_writer.deinit();
    const nested = [_]Value{ Value.mkInt(1), Value.mkClosure(ignoreBody, no_env) };
    try std.testing.expectError(error.Unencodable, encode(&nested_writer, gpa, Value.mkArray(&nested)));
    try std.testing.expectEqual(@as(usize, 0), nested_writer.bytes().len);
}

test "decode rejects truncated input" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Every buffer below starts with `version`; only the bytes AFTER it vary, so
    // each case is about its own rejection and not about the prefix.
    try expectDecodeError(gpa, &.{}, error.Truncated);
    try expectDecodeError(gpa, &.{version}, error.Truncated);
    try expectDecodeError(gpa, &.{ version, tag.string }, error.Truncated);
    try expectDecodeError(gpa, &.{ version, tag.string, 0, 0 }, error.Truncated);
    try expectDecodeError(gpa, &.{ version, tag.array, 1, 0, 0, 0, tag.string, 0, 0 }, error.Truncated);
}

test "decode rejects a length or count larger than the remaining bytes" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A string that claims 4 GiB - 1.
    try expectDecodeError(gpa, &.{ version, tag.string, 0xff, 0xff, 0xff, 0xff }, error.OversizedLength);
    // A string that claims 4 bytes with one present.
    try expectDecodeError(gpa, &.{ version, tag.string, 4, 0, 0, 0, 'a' }, error.OversizedLength);
    // An array that claims 16 elements with none present.
    try expectDecodeError(gpa, &.{ version, tag.array, 16, 0, 0, 0 }, error.OversizedLength);
    // A record that claims 2 fields with 1 byte present.
    try expectDecodeError(gpa, &.{ version, tag.record, 2, 0, 0, 0, tag.unit }, error.OversizedLength);
    // A data tag string longer than the buffer.
    try expectDecodeError(gpa, &.{ version, tag.data, 9, 0, 0, 0, 'J' }, error.OversizedLength);
}

test "decode rejects an unknown tag" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectDecodeError(gpa, &.{ version, 0x0c }, error.UnknownTag);
    try expectDecodeError(gpa, &.{ version, 0x7f }, error.UnknownTag);
    try expectDecodeError(gpa, &.{ version, 0xff, 0x00 }, error.UnknownTag);
}

test "decode rejects the reserved closure, ref and marray tags" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectDecodeError(gpa, &.{ version, tag.closure }, error.Unencodable);
    try expectDecodeError(gpa, &.{ version, tag.ref }, error.Unencodable);
    try expectDecodeError(gpa, &.{ version, tag.marray }, error.Unencodable);
}

test "decode rejects trailing bytes after a complete value" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectDecodeError(gpa, &.{ version, tag.unit, tag.unit }, error.TrailingBytes);
    try expectDecodeError(gpa, &.{ version, tag.boolean, 1, 0x00 }, error.TrailingBytes);
    // A complete array, then a stray byte.
    try expectDecodeError(gpa, &.{ version, tag.array, 1, 0, 0, 0, tag.unit, tag.unit }, error.TrailingBytes);
}

test "decode rejects an out-of-range char and a non-boolean boolean byte" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try expectDecodeError(gpa, &.{ version, tag.char, 0x00, 0x00, 0x11, 0x00 }, error.InvalidChar);
    try expectDecodeError(gpa, &.{ version, tag.boolean, 2 }, error.InvalidBoolean);
}

test "encode and decode stop at MAX_DEPTH" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Exactly MAX_DEPTH nested arrays encode and decode; one more does not.
    const allowed = try nest(gpa, MAX_DEPTH);
    try expectCanonical(gpa, allowed);

    const too_deep = try nest(gpa, MAX_DEPTH + 1);
    var w = Writer.init(gpa);
    defer w.deinit();
    try std.testing.expectError(error.DepthExceeded, encode(&w, gpa, too_deep));

    // The same bound on the way in, built by hand: the version byte, then 65
    // arrays, then a unit.
    var input: [1 + (5 * (MAX_DEPTH + 1)) + 1]u8 = undefined;
    var written: usize = 0;
    input[written] = version;
    written += 1;
    var i: usize = 0;
    while (i < MAX_DEPTH + 1) : (i += 1) {
        input[written] = tag.array;
        input[written + 1] = 1;
        input[written + 2] = 0;
        input[written + 3] = 0;
        input[written + 4] = 0;
        written += 5;
    }
    input[written] = tag.unit;
    var r = Reader.init(&input);
    try std.testing.expectError(error.DepthExceeded, decode(&r, gpa));
}

/// `n` nested single-element arrays around `unit`.
fn nest(gpa: std.mem.Allocator, n: usize) !Value {
    var value = Value.mkUnit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const items = try gpa.alloc(Value, 1);
        items[0] = value;
        value = Value.mkArray(items);
    }
    return value;
}

test "two writers over one allocator produce the same bytes" {
    var arena = arenaOf(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // `Writer` is a sink, not a per-value buffer: encoding the same value into
    // two writers gives the same bytes, and the framing starts at the version.
    var first = Writer.init(gpa);
    defer first.deinit();
    try encode(&first, gpa, Value.mkInt(1));

    var second = Writer.init(gpa);
    defer second.deinit();
    try encode(&second, gpa, Value.mkInt(1));

    try std.testing.expectEqualSlices(u8, first.bytes(), second.bytes());
    try std.testing.expectEqualSlices(u8, &.{ version, tag.integer, 1, 0, 0, 0 }, first.bytes());
}
