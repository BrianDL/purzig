#!/bin/sh
# purzig's failure reporter: run one external build command and never swallow
# what it said.
#
# WHY THIS EXISTS (issue #31)
#
# `spago build` is the step that runs purs and then the purzig backend. When it
# fails, all a build used to leave behind was
#
#     run spago failure
#     error: process exited with error code 1
#
# -- and the compiler's actual error block, the only thing that says WHAT to
# fix, was gone. A consumer's first mistyped import cost two repair round trips
# and a throwaway harness. So the command is wrapped here, its stdout and
# stderr are captured MERGED (in the order the child wrote them, the way a
# terminal would show them), and on failure the whole of it is printed between
# markers before the failure summary.
#
# Rules this follows, from the issue:
#
#   * never truncate. No `tail`: the first error is usually the relevant one
#     and the last line is usually a summary, so both are kept;
#   * on success, print nothing. A green build's log stays exactly as quiet as
#     it is today, because consumers read those logs;
#   * name the phase, because the fix differs per phase:
#       - type-check failure   purs rejected the source;
#       - backend failure      purs type-checked, purzig could not emit Zig;
#       - backend unavailable  the `purzig` shim was not on PATH at all -- the
#                              shape a manual `spago build` fails in;
#       - missing artifact     the backend finished, but `output-zig/<main>.zig`
#                              is not on disk for the build to compile;
#       - command failure      `spago` itself failed for some other reason.
#
# A note on the backend, because it is the surprising half: the purzig backend
# does NOT fail its process on a module it cannot emit. It logs
# `[purs-backend-zig] <Module>: EMIT FAILED -- <reason>` (or `MISSING FFI`) and
# carries on, so `spago build` exits 0 and the failure only shows up later, as
# a Zig error about a missing file inside generated code. The scan below turns
# those logged failures into a failed build with the backend's own message,
# which is what "backend failure" has to mean in practice.
#
# ASSERTION MODE
#
# `--expect-failure` is how `zig build test-diagnostics` gates this file: the
# command must fail (or be marked failed by the backend), and the report -- the
# markers, the phase sentence and the child's untruncated output -- must
# contain every `--require` string (fixed) and match every `--require-re`
# (extended regular expression). Exit 0 then means "the diagnostics are right";
# a missing needle names itself. The gate asserts the same text a user reads,
# produced by the same code path the build uses.
#
# This is POSIX sh on purpose: it is invoked as `sh <this file>`, so it needs
# no executable bit, and /bin/sh is the only interpreter purzig assumes.

set -u

label=command
main_module=
expect_failure=0
shim_dir=.zig-cache/purzig-bin

usage() {
    echo "usage: purzig-run.sh [--label LABEL] [--main-module NAME]" >&2
    echo "                     [--shim-dir DIR] [--expect-failure]" >&2
    echo "                     [--require STRING]... [--require-re ERE]..." >&2
    echo "                     -- COMMAND [ARG]..." >&2
    exit 2
}

if ! tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/purzig-run.XXXXXX" 2>/dev/null); then
    tmpdir=${TMPDIR:-/tmp}/purzig-run.$$
    mkdir -p "$tmpdir" || {
        echo "purzig: cannot create a scratch directory for the command's output" >&2
        exit 2
    }
fi

needles=$tmpdir/needles
regexes=$tmpdir/regexes
report=$tmpdir/report
: >"$needles"
: >"$regexes"
: >"$report"

cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT HUP INT TERM

while [ $# -gt 0 ]; do
    case $1 in
    --label)
        shift
        [ $# -gt 0 ] || usage
        label=$1
        shift
        ;;
    --main-module)
        shift
        [ $# -gt 0 ] || usage
        main_module=$1
        shift
        ;;
    --shim-dir)
        shift
        [ $# -gt 0 ] || usage
        shim_dir=$1
        shift
        ;;
    --expect-failure)
        expect_failure=1
        shift
        ;;
    --require)
        shift
        [ $# -gt 0 ] || usage
        printf '%s\n' "$1" >>"$needles"
        shift
        ;;
    --require-re)
        shift
        [ $# -gt 0 ] || usage
        printf '%s\n' "$1" >>"$regexes"
        shift
        ;;
    --)
        shift
        break
        ;;
    *) usage ;;
    esac
done
[ $# -gt 0 ] || usage

# The step's cwd IS the project (the same directory `spago build` is given under
# the old wiring), so everything relative below lands beside the sources, next
# to the `.purzig/packages.json` the build has already copied in.
project=$(pwd -P 2>/dev/null || pwd)

log_dir=$project/.purzig/logs
slug=$(printf '%s' "$label" | tr -c 'a-zA-Z0-9\n' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$slug" ] || slug=command
if ! mkdir -p "$log_dir" 2>/dev/null; then
    # A read-only project is not a reason to lose the diagnostics.
    log_dir=$tmpdir
fi
log=$log_dir/$slug.log

# ---- 1. run it, merged, in order ------------------------------------------

"$@" >"$log" 2>&1
status=$?

# ---- 2. name the phase ----------------------------------------------------

phase=
detail=
advice=
extra=

if [ "$status" -ne 0 ]; then
    marker="--- purzig: \`$label\` failed (exit $status) — output follows ---"
    if grep -q -e '\[ERROR ' "$log" 2>/dev/null; then
        phase="type-check failure"
        detail="purs rejected the source, so purzig never ran; purs's own errors are printed below, verbatim."
    elif grep -q -e 'Failed to build with backend' "$log" 2>/dev/null; then
        if grep -q -e '\[purs-backend-zig\]' "$log" 2>/dev/null; then
            phase="backend failure"
            detail="purs type-checked the source, but the purzig backend could not emit Zig; the backend's own output is below."
        else
            phase="backend unavailable"
            detail="\`$label\` could not run the purzig backend at all, so nothing is wrong with the source yet."
        fi
    else
        phase="command failure"
        detail="\`$label\` itself failed; its output is below, untruncated."
    fi
else
    # `spago build` exited 0. The backend logs its failures instead of failing,
    # so a zero exit is not the end of the story.
    if grep -q -e 'EMIT FAILED' "$log" 2>/dev/null; then
        marker="--- purzig: \`$label\` exited 0, but the purzig backend failed to emit a module — output follows ---"
        phase="backend failure"
        detail="purs type-checked the source, but the purzig backend reported EMIT FAILED and wrote no Zig for that module; its own message is below."
    elif grep -q -e 'MISSING FFI' "$log" 2>/dev/null; then
        marker="--- purzig: \`$label\` exited 0, but the purzig backend rejected a module — output follows ---"
        phase="backend failure"
        detail="purs type-checked the source, but the purzig backend found a foreign import with no Zig FFI beside the .purs file; its own message is below."
    elif [ -n "$main_module" ] && [ ! -s "output-zig/$main_module.zig" ]; then
        marker="--- purzig: \`$label\` exited 0, but output-zig/$main_module.zig is missing — output follows ---"
        phase="missing artifact"
        detail="the backend finished without reporting an error, but the file the build is about to compile is not on disk."
        advice="check Options.main_module in build.zig: it names the module that exports \`main\`, not a source file."
        if [ -f output-zig/manifest.json ]; then
            extra="purzig: output-zig/manifest.json, as the backend left it:"
            extra="$extra
$(cat output-zig/manifest.json)"
        fi
    fi
fi

if [ "$phase" = "backend unavailable" ]; then
    advice="purzig: the purzig-driven build puts a shim named \`purzig\` on PATH for this step alone ($shim_dir), and copies the package set to $project/.purzig/packages.json.
purzig: a manual run must do the same. There is a wrapper that already does: cd into the project and run '$project/.purzig/spago build' -- it puts that shim on PATH and execs the real spago, so a hand run and a purzig-driven run agree on the same tree."
fi

# ---- 3. report it ---------------------------------------------------------

if [ -n "$phase" ]; then
    {
        printf '%s\n' "$marker"
        printf 'purzig: %s — %s\n' "$phase" "$detail"
        if [ -n "$advice" ]; then printf '%s\n' "$advice"; fi
        if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
        printf 'purzig: everything `%s` wrote follows, in order and untruncated (also saved in %s):\n' "$label" "$log"
        printf '%s\n' "--- \`$label\` output ---"
        cat "$log"
        printf '%s\n' "--- end of \`$label\` output ---"
    } >"$report"

    cat "$report" >&2
    # If the build runner captured our stderr, a human watching the terminal
    # would still see nothing. Write to the terminal directly when stderr is
    # not one, and stay silent when it is (so nothing is printed twice).
    if [ ! -t 2 ] && ( : >/dev/tty ) 2>/dev/null; then
        cat "$report" >/dev/tty 2>/dev/null || true
    fi
fi

# ---- 4. assertion mode, for `zig build test-diagnostics` -------------------

if [ "$expect_failure" -eq 1 ]; then
    failed=0
    if [ -z "$phase" ]; then
        echo "purzig-diagnostics: FAIL — expected \`$label\` to fail in $project, but it succeeded and purzig had nothing to report" >&2
        exit 1
    fi
    while IFS= read -r needle; do
        [ -n "$needle" ] || continue
        if grep -q -F -e "$needle" "$report"; then
            echo "purzig-diagnostics: ok — the report contains \"$needle\""
        else
            echo "purzig-diagnostics: FAIL — the report does not contain \"$needle\"" >&2
            failed=1
        fi
    done <"$needles"
    while IFS= read -r re; do
        [ -n "$re" ] || continue
        if grep -q -E -e "$re" "$report"; then
            echo "purzig-diagnostics: ok — the report matches /$re/"
        else
            echo "purzig-diagnostics: FAIL — the report does not match /$re/" >&2
            failed=1
        fi
    done <"$regexes"
    if [ "$failed" -ne 0 ]; then
        echo "purzig-diagnostics: FAIL — \`$label\` in $project did not report what purzig promises (phase: $phase)" >&2
        exit 1
    fi
    echo "purzig-diagnostics: PASS — \`$label\` in $project failed as $phase and said why"
    exit 0
fi

if [ "$status" -ne 0 ]; then
    exit "$status"
fi
if [ -n "$phase" ]; then
    exit 1
fi
exit 0
