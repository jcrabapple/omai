#!/usr/bin/env bash
# Build a signed release APK of Omai and optionally install it on a device.
#
#   dev/release.sh                 # build with the version in pubspec.yaml
#   dev/release.sh --bump patch    # bump x.y.Z and the build number first
#   dev/release.sh --bump minor    # x.Y.0
#   dev/release.sh --install       # also adb install on the connected phone
#
# Signing: ~/.config/omai-signing/key.properties (or $OMAI_KEY_PROPERTIES).
# Refuses to build a release signed with the debug key. Output lands in
# dist/omai-<version>.apk (gitignored) with a .sha256 beside it.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export JAVA_HOME="${JAVA_HOME:-$HOME/.local/share/jbr}"

bump="" install=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bump) bump="$2"; shift 2 ;;
    --install) install=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

keyprops="${OMAI_KEY_PROPERTIES:-$HOME/.config/omai-signing/key.properties}"
[ -f "$keyprops" ] || { echo "no release key at $keyprops; refusing to ship a debug-signed release" >&2; exit 1; }

if [ -n "$bump" ]; then
  python3 - "$bump" <<'PY'
import re, sys, pathlib
kind = sys.argv[1]
p = pathlib.Path("pubspec.yaml")
s = p.read_text()
m = re.search(r"^version: (\d+)\.(\d+)\.(\d+)\+(\d+)$", s, re.M)
assert m, "pubspec version must look like X.Y.Z+N"
x, y, z, n = map(int, m.groups())
if kind == "major": x, y, z = x + 1, 0, 0
elif kind == "minor": y, z = y + 1, 0
elif kind == "patch": z += 1
else: sys.exit(f"--bump must be major|minor|patch, got {kind}")
new = f"version: {x}.{y}.{z}+{n + 1}"
p.write_text(s[:m.start()] + new + s[m.end():])
print(new)
PY
fi

version=$(sed -n 's/^version: \(.*\)$/\1/p' pubspec.yaml)
name=${version%%+*}

flutter analyze
flutter test
flutter build apk --release

apk=build/app/outputs/flutter-apk/app-release.apk
bt=$(ls -d "$HOME"/Android/Sdk/build-tools/*/ | sort -V | tail -1)
certs=$("$bt/apksigner" verify --print-certs "$apk")
if grep -q "CN=Android Debug" <<<"$certs"; then
  echo "release APK is debug-signed; aborting" >&2; exit 1
fi

mkdir -p dist
out="dist/omai-$name.apk"
cp "$apk" "$out"
( cd dist && sha256sum "omai-$name.apk" > "omai-$name.apk.sha256" )
echo "built $out ($version)"
grep "certificate SHA-256" <<<"$certs" | head -1

if [ "$install" = 1 ]; then
  adb install --user 0 -r "$out"
fi
