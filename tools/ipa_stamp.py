#!/usr/bin/env python3
"""Rewrite the version metadata of an unsigned .ipa.

A compile-time IPA can only be produced on a macOS runner. When that runner is
not available, a release still needs an installable bundle, so the last good
build is re-published with the release version stamped into its Info.plist.
Only the plist entry changes: every other file, including the Mach-O, is copied
byte for byte.

usage: ipa_stamp.py <in.ipa> <out.ipa> <marketing-version> <build-number>
"""

import os
import plistlib
import sys
import zipfile


def stamp(src: str, dst: str, version: str, build: str) -> None:
    # Write beside the target and rename at the end: a rejected archive must not
    # leave a half-built IPA behind for a release step to pick up.
    tmp = dst + ".partial"
    stamped = 0
    try:
        with zipfile.ZipFile(src) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                data = zin.read(item.filename)
                if item.filename.startswith("Payload/") and item.filename.endswith(".app/Info.plist"):
                    info = plistlib.loads(data)
                    info["CFBundleShortVersionString"] = version
                    info["CFBundleVersion"] = build
                    data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY)
                    stamped += 1
                zout.writestr(item, data)
        if stamped != 1:
            raise SystemExit(f"expected exactly one app Info.plist, found {stamped}")
        os.replace(tmp, dst)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print(f"stamped {version} ({build}) into {dst}")


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    stamp(*sys.argv[1:])
    return 0


if __name__ == "__main__":
    sys.exit(main())
