//! FFI for Control.Apply.

const rt = @import("runtime");
const Value = rt.Value;

/// The array Applicative: every function applied to every argument, in
/// function-major order.
///
/// Fallible: the elements of `fs` are PureScript functions and may throw. An
/// error abandons the partly-filled output, which is correct -- the arena owns
/// it and nothing observes a half-built array.
fn arrayApply(fs: Value, xs: Value) rt.Error!Value {
    const functions = fs.asArray();
    const arguments = xs.asArray();

    const out = rt.alloc().alloc(Value, functions.len * arguments.len) catch
        @panic("runtime: out of memory");

    var n: usize = 0;
    for (functions) |f| {
        for (arguments) |x| {
            out[n] = try rt.apply(f, x);
            n += 1;
        }
    }
    return Value.mkArray(out);
}

pub const @"ps.arrayApply" = rt.curry(arrayApply);
