#!/usr/bin/env bash
# Build Events for an iOS device: the `ios-device` target of barry.app.yaml.
#
# Ported from `barry ios build --device`, which built the apps bag.yaml used to
# declare under `apps:`. That command is gone with `apps:`; a native app now
# names a build script in package.json, and `barry app install` runs it and
# prints how to put the bundle on a phone (xcrun devicectl device install app).
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Events.xcodeproj"
SCHEME="Events"
# Where barry.app.yaml's install.ios-device.bundle points, absolute because
# xcodebuild resolves CONFIGURATION_BUILD_DIR against the project.
OUT="$(cd "." && pwd)/.build"

# The reverse-DNS prefix every app's bundle id derives from (project.yml's
# bundleIdPrefix). Always set, never left to the environment: XcodeGen writes
# an unset ${VAR} into PRODUCT_BUNDLE_IDENTIFIER literally and exits 0. A fork
# sets BARRY_BUNDLE_PREFIX=com.example for every app at once.
PREFIX="${BARRY_BUNDLE_PREFIX:-rocks.barry}"
if ! [[ "$PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "BARRY_BUNDLE_PREFIX is not a valid reverse-DNS prefix: \"$PREFIX\" (expected something like com.example)" >&2
  exit 1
fi

# The Apple team to sign with. Never read from a manifest: it is per machine
# and per Apple ID. BARRY_IOS_TEAM_ID wins; otherwise it comes from any
# provisioning profile Xcode has already created.
TEAM="${BARRY_IOS_TEAM_ID:-}"
if [[ -z "$TEAM" ]]; then
  for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    [[ -e "$profile" ]] || continue
    TEAM="$(security cms -D -i "$profile" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)"
    [[ -n "$TEAM" ]] && break
  done
fi
if [[ -z "$TEAM" ]]; then
  echo "no Apple team found — sign into Xcode, or set BARRY_IOS_TEAM_ID" >&2
  exit 1
fi

# Regenerate every time: xcodegen globs the source directories, so a file added
# since the last generate is absent from the project and the build "succeeds"
# without it.
BARRY_BUNDLE_PREFIX="$PREFIX" xcodegen generate

# project.yml keeps the simulator posture (CODE_SIGNING_ALLOWED: NO) so a fresh
# clone builds without provisioning; device signing is layered on here instead.
mkdir -p "$OUT"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath .build-barry-ios \
  -destination "generic/platform=iOS" \
  -allowProvisioningUpdates \
  "CONFIGURATION_BUILD_DIR=$OUT" \
  "DEVELOPMENT_TEAM=$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  build

# A zero exit with no bundle is the failure this check exists for: the stale
# previous install would otherwise silently stay on the phone.
if [[ ! -f "$OUT/$SCHEME.app/Info.plist" ]]; then
  echo "build reported success but produced no iOS app bundle at $OUT/$SCHEME.app" >&2
  exit 1
fi
echo "Built $OUT/$SCHEME.app"
