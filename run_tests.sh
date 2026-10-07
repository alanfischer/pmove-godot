#!/bin/bash
# Runs the pmove suites and exits non-zero if any fails.
set -uo pipefail

# Resolve the Godot binary: $GODOT override, then the two common install paths.
GODOT="${GODOT:-}"
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
    for candidate in \
        "/Applications/Godot.app/Contents/MacOS/Godot" \
        "$HOME/Applications/Godot.app/Contents/MacOS/Godot" \
        "$(command -v godot 2>/dev/null)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then GODOT="$candidate"; break; fi
    done
fi
if [ ! -x "$GODOT" ]; then
    echo "Godot binary not found. Set GODOT=/path/to/Godot" >&2
    exit 127
fi

cd "$(dirname "$0")"

# A GDScript runtime error (a bad call, a wrong-typed index) kills only the frame it happens in:
# the test's remaining assertions never run, the suite counts no failure, and the run goes green
# holding a broken test. The assertion counts cannot see it, so the output is the only witness --
# and a clean run prints no SCRIPT ERROR at all, which makes it a reliable tripwire.
status=0
log="$(mktemp)"
if ! "$GODOT" --headless --path . -s res://tests/run_tests.gd 2>&1 | tee "$log"; then
    status=1
fi
if grep -q "SCRIPT ERROR" "$log"; then
    echo
    echo "SCRIPT ERROR -- a test hit a runtime error and silently dropped its remaining" >&2
    echo "assertions, so its result means nothing. First occurrences:" >&2
    grep -m 5 -A2 "SCRIPT ERROR" "$log" >&2
    status=1
fi
rm -f "$log"
exit "$status"
