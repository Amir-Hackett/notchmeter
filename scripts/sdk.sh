# Sourced by scripts/test.sh and scripts/build.sh: picks a macOS SDK the selected toolchain can build against.
#
# The package is developed on Command Line Tools alone, and the tools ship more than one SDK with MacOSX.sdk
# pointing at the newest. From the macOS 27 SDK on, SwiftUI declares @State and its relatives as macros whose
# implementation is a compiler plugin, SwiftUIMacros, and that plugin ships with Xcode and not with the tools. A
# tools update on 2026-11-09 moved MacOSX.sdk to 27.2, and every build then stopped at the first view:
#
#     external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()';
#     plugin for module 'SwiftUIMacros' not found
#
# Nothing in the code had changed, and the 26.5 SDK installed beside it built as before.
#
# So the default SDK is asked the question directly: does a three-line view with an @State type-check against
# it? If it does, nothing is set and the build is the build it always was, which is every machine with Xcode
# selected, CI and the release runners among them. If it does not, the SDKs installed beside it are tried
# newest first and the first that answers yes is exported as SDKROOT, which swift build and swift test both
# honour. If none does, nothing is set and the build reports the real error itself.
#
# The probe compiles SwiftUI's module from its interface the first time an SDK is asked, about twenty seconds,
# and answers from the compiler's module cache in a fraction of a second after that.
#
# A caller that sets SDKROOT has already chosen, and is left alone.
pick_sdk() {
  [ -z "${SDKROOT:-}" ] || return 0
  local default candidate
  default="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || return 0
  sdk_builds_swiftui "$default" && return 0
  while IFS= read -r candidate; do
    # MacOSX.sdk and MacOSX27.sdk are links to an SDK the loop reaches by its own name.
    [ -L "$candidate" ] && continue
    if sdk_builds_swiftui "$candidate"; then
      export SDKROOT="$candidate"
      echo "note: $(basename "$default") cannot build SwiftUI with this toolchain (no SwiftUIMacros plugin); using $(basename "$candidate")" >&2
      return 0
    fi
  done < <(ls -d "$(dirname "$default")"/MacOSX*.sdk 2>/dev/null | sort -rV)
  return 0
}

sdk_builds_swiftui() {
  printf 'import SwiftUI\nstruct Probe: View { @State var on = false; var body: some View { Text("") } }\n' \
    | swiftc -typecheck -sdk "$1" - >/dev/null 2>&1
}
