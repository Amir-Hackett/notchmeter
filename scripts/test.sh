#!/bin/bash
# Runs the unit tests. Command Line Tools ship Swift Testing without the Foundation cross-import
# module, so the framework path is passed explicitly and cross-import overlays are disabled.
# Xcode keeps the same frameworks under its macOS platform; a toolchain with neither layout is
# left to resolve Testing on its own.
# Tests that need UserDefaults use fixed suite names (NotchmeterTests.*) emptied before and after,
# so a run leaves nothing new under ~/Library/Preferences (docs/testing.md).
#
# --no-parallel: several suites touch AppKit (NSScreen, the panel geometry, the asset renderer), and Swift
# Testing otherwise starts every test at once. On a machine with no Window Server session, which is every CI
# runner, two of them racing the first connection abort the whole process inside CoreGraphics rather than
# failing a test:
#
#     Assertion failed: (CGAtomicGet(&is_initialized)), function CGSConnectionByID, file CGSConnection.mm
#
# It took the first run of the release workflow down on 2026-09-05 and a pull request an hour later, having
# passed a dozen times in between, which is the shape of a race and the reason not to leave it: a release that
# publishes on a coin flip is worse than a slow one. Serially the suite takes a few minutes rather than ninety
# seconds, and the answer is the same every time.
#
# -solver-scope-threshold: the type checker gives up on an expression once its constraint solver has opened more
# scopes than a fixed budget, and reports "unable to type-check this expression in reasonable time". The name says
# time; the mechanism is a counter, so the answer is the same on every machine and every run. The default budget is
# 2^20 scopes. Nothing here comes close -- the most expensive expression in Sources/ and Tests/ together sits under
# 2^15 -- but one had drifted to 2^17 and another went past 2^20 and took the whole test target's compile down with
# it, so `swift test` reported `error: fatalError` having run no tests at all (8ad388e). Both were the same shape:
# bare numeric literals doing arithmetic inside #expect, whose expansion wraps every operand in a tree of
# callAsFunction overloads so it can report which side differed. Naming the expected value first costs one line and
# resolves the literals before the macro is handed them.
#
# Building at 2^17 gives up 8x sooner than the compiler would, which turns that cliff into a build error on the pull
# request that writes the expression rather than a mystery on a later unrelated one. 2^18 was tried first and was
# too loose: it caught the expression that had already gone over, but not the 2^17 one sitting a single careless
# edit behind it, which is the case worth catching. This leaves 4x room above today's worst expression: if it starts
# firing on honest code rather than on literals that want a name, raise it, and only worry past 2^20.
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER="$(xcode-select -p)"
SOLVER=(-Xswiftc -Xfrontend -Xswiftc -solver-scope-threshold=131072)
for FW in "$DEVELOPER/Library/Developer/Frameworks" "$DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"; do
  if [ -d "$FW/Testing.framework" ]; then
    exec swift test --no-parallel "${SOLVER[@]}" \
      -Xswiftc -F"$FW" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
      -Xlinker -F"$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
  fi
done
exec swift test --no-parallel "${SOLVER[@]}" "$@"
