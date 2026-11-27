#!/usr/bin/env bash
# tools/ipa_stamp.py: re-publish an existing unsigned IPA under a release
# version. The release workflow relies on it when no macOS runner builds the
# tag, so it must change the plist and nothing else.
set -uo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="$PROJECT_DIR/tools/ipa_stamp.py"

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

checks=0
failures=0
check() {
    local name="$1"; shift
    checks=$((checks + 1))
    if "$@"; then printf 'ok %d - %s\n' "$checks" "$name"
    else printf 'not ok %d - %s\n' "$checks" "$name"; failures=$((failures + 1)); fi
}

command -v python3 >/dev/null 2>&1 || { echo '1..0 # SKIP python3 missing'; exit 0; }

# Build a miniature IPA: Payload/App.app/{Info.plist,binary}
make_ipa() { # <path> [with-plist]
    local ipa="$1" with="${2:-yes}" root
    root=$(mktemp -d "$tmpdir/app.XXXXXX")
    mkdir -p "$root/Payload/App.app"
    printf 'MACHO-BINARY-CONTENT\n' > "$root/Payload/App.app/App"
    chmod 0755 "$root/Payload/App.app/App"
    printf 'APPL????' > "$root/Payload/App.app/PkgInfo"
    if [ "$with" = yes ]; then
        python3 - "$root/Payload/App.app/Info.plist" <<'PY'
import plistlib, sys
info = {"CFBundleIdentifier": "com.example.app",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": "16.0"}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(info, fh, fmt=plistlib.FMT_BINARY)
PY
    fi
    ( cd "$root" && zip -qr "$ipa" Payload )
}

plist_field() { # <ipa> <field>
    python3 - "$1" "$2" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    info = plistlib.loads(z.read("Payload/App.app/Info.plist"))
print(info.get(sys.argv[2], ""))
PY
}

entry_hash() { # <ipa> <entry>
    python3 - "$1" "$2" <<'PY'
import hashlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print(hashlib.sha256(z.read(sys.argv[2])).hexdigest())
PY
}

inp="$tmpdir/in.ipa"
out="$tmpdir/out.ipa"
make_ipa "$inp"

check "tool exists"                 test -f "$TOOL"
check "tool compiles"               python3 -m py_compile "$TOOL"
check "stamping succeeds"           python3 "$TOOL" "$inp" "$out" 1.2.0 2
check "marketing version is stamped" test "$(plist_field "$out" CFBundleShortVersionString)" = 1.2.0
check "build number is stamped"      test "$(plist_field "$out" CFBundleVersion)" = 2
check "other plist keys are kept"    test "$(plist_field "$out" CFBundleIdentifier)" = com.example.app
check "minimum OS is kept"           test "$(plist_field "$out" MinimumOSVersion)" = 16.0
check "binary is byte-identical" \
    test "$(entry_hash "$inp" Payload/App.app/App)" = "$(entry_hash "$out" Payload/App.app/App)"
check "PkgInfo is kept"              test "$(entry_hash "$inp" Payload/App.app/PkgInfo)" = "$(entry_hash "$out" Payload/App.app/PkgInfo)"
check "archive still lists Payload"  bash -c 'python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); sys.exit(0 if \"Payload/App.app/PkgInfo\" in z.namelist() else 1)" "$1"' _ "$out"
check "archive is a valid zip"       bash -c 'python3 -c "import zipfile,sys; sys.exit(0 if zipfile.ZipFile(sys.argv[1]).testzip() is None else 1)" "$1"' _ "$out"

# An IPA without an Info.plist must fail loudly instead of shipping silently.
broken="$tmpdir/broken.ipa"
make_ipa "$broken" no
check "missing Info.plist is rejected" bash -c '! python3 "$1" "$2" "$2.out" 1.2.0 2 >/dev/null 2>&1' _ "$TOOL" "$broken"
check "nothing is written on failure"  test ! -f "$broken.out"
check "wrong argument count is rejected" bash -c '! python3 "$1" "$2"' _ "$TOOL" "$inp"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
