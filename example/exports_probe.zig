//! The typed-ABI gate (issue #33): assert the `exports` rows `Zig.Abi` publishes
//! for `example/src/Shapes.purs`.
//!
//! This probe reads `example/output-zig/manifest.json` and nothing else. It is
//! deliberately NOT a JSON parser: it asserts the exact rendered ROW TEXT, which
//! is stricter than a field-by-field comparison (a row that is present but
//! shaped differently is a missing row here) and needs no allocator, no
//! `std.json`, and no file I/O at all.
//!
//! The manifest is `@embedFile`-ed, which is why this file sits at `example/`
//! rather than in `example/abi/`: `@embedFile` resolves against the containing
//! file's directory, so `output-zig/manifest.json` means
//! `example/output-zig/manifest.json` -- the path the codegen writes, with no
//! `..` and so no doubt about escaping a root. That is also why the probe's
//! step depends on the codegen step: the file must exist when the probe is
//! COMPILED, not when the build script is configured. Nothing here reads the
//! manifest at configure time -- Zig 0.16 has no build-script filesystem.
//!
//! `zig build test-exports` asserts this program's stdout is exactly
//! `ok 6 Shapes export rows`, and `zig build test` depends on it.

const std = @import("std");

const manifest: []const u8 = @embedFile("output-zig/manifest.json");

// One row per shape in the vocabulary, as `Zig.Abi.renderExport` renders it.
// `fHo` is the deliberate refusal: a function as an argument has no shape, so
// the row must say so by name instead of publishing something encodable.
const expected_rows = [_][]const u8{
    "{ \"module\": \"Shapes\", \"name\": \"fInt\", \"args\": [\"int\"], \"result\": \"int\" }",
    "{ \"module\": \"Shapes\", \"name\": \"fStr\", \"args\": [\"string\"], \"result\": \"string\" }",
    "{ \"module\": \"Shapes\", \"name\": \"fArr\", \"args\": [{\"array\": \"int\"}], \"result\": {\"array\": \"int\"} }",
    "{ \"module\": \"Shapes\", \"name\": \"fRec\", \"args\": [{\"record\": {\"a\": \"int\", \"b\": \"string\"}}], \"result\": \"int\" }",
    "{ \"module\": \"Shapes\", \"name\": \"fAdt\", \"args\": [{\"adt\": {\"module\": \"Shapes\", \"name\": \"Shape\"}}], \"result\": \"int\" }",
    "{ \"module\": \"Shapes\", \"name\": \"fHo\", \"args\": [{\"refused\": \"higher-order argument\"}], \"result\": \"int\" }",
};

// Every Shapes row starts with this, whatever its shapes are: counting them is
// how "no export was silently dropped" becomes an assertion. `Shapes` declares
// exactly six annotated top-level functions.
const shapes_row_prefix = "{ \"module\": \"Shapes\", ";

pub fn main(init: std.process.Init) !void {
    var failures: usize = 0;

    for (expected_rows) |row| {
        if (std.mem.indexOf(u8, manifest, row) == null) {
            std.debug.print(
                "exports-probe: missing or wrong export row (issue #33):\n  {s}\n",
                .{row},
            );
            failures += 1;
        }
    }

    const shapes_rows = countOccurrences(manifest, shapes_row_prefix);
    if (shapes_rows != expected_rows.len) {
        std.debug.print(
            "exports-probe: expected {d} Shapes export rows, found {d} -- an export was dropped, " ++
                "either because docs.json did not list it or because the manifest omitted it\n",
            .{ expected_rows.len, shapes_rows },
        );
        failures += 1;
    }

    // The rest of the manifest must be untouched by the new array: the older
    // keys keep their shape, so a consumer written against them still works.
    if (std.mem.indexOf(u8, manifest, "\"main_module\": \"Main\"") == null) {
        std.debug.print("exports-probe: manifest lost `main_module`\n", .{});
        failures += 1;
    }
    if (std.mem.indexOf(u8, manifest, "\"modules\": [") == null) {
        std.debug.print("exports-probe: manifest lost `modules`\n", .{});
        failures += 1;
    }
    if (std.mem.indexOf(u8, manifest, "\"exports\": [") == null) {
        std.debug.print("exports-probe: manifest lost `exports`\n", .{});
        failures += 1;
    }

    if (failures != 0) return error.ExportsProbeFailed;

    const out = std.Io.File.stdout();
    out.writeStreamingAll(init.io, "ok 6 Shapes export rows\n") catch return error.ExportsProbeFailed;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        count += 1;
        rest = rest[i + needle.len ..];
    }
    return count;
}
