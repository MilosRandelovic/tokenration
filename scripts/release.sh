#!/usr/bin/env bash

# Build, sign and publish TokenRation.app, then update the Homebrew cask's version and
# checksum. Run by CI on a version bump; also runnable locally.
#
# With a "Developer ID Application" certificate available the app is signed with the hardened
# runtime, notarized and stapled. Set ALLOW_UNSIGNED=1 to fall back to an ad-hoc build, which
# installs but is quarantined by Gatekeeper on first launch.
#
# Environment:
#   ALLOW_UNSIGNED  1 to allow an ad-hoc build when no certificate is present
#   SIGN_IDENTITY   signing identity to use instead of the first Developer ID found
#   NOTARY_PROFILE  stored notarytool credential profile (default: TokenRation-notary)
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                   notary credentials, used instead of a stored profile
#   TAP_CASK        cask file to update (default: ../homebrew-tokenration/Casks/tokenration.rb)
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/common.sh

NOTARY_PROFILE="${NOTARY_PROFILE:-TokenRation-notary}"

# 1. Locate the Developer ID Application signing identity.
ALLOW_UNSIGNED="${ALLOW_UNSIGNED:-0}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
NOTARIZE=1
if [ -z "$IDENTITY" ]; then
  if [ "$ALLOW_UNSIGNED" = "1" ]; then
      echo "==> No Developer ID certificate — building AD-HOC signed, NOT notarized."
      echo "    Gatekeeper will block first launch on other Macs; the cask explains the fix."
      IDENTITY="-"
      NOTARIZE=0
  else
      echo "ERROR: No 'Developer ID Application' certificate in your Keychain." >&2
      echo "You currently have:" >&2
      security find-identity -v -p codesigning | sed 's/^/    /' >&2
      echo "Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸" >&2
      echo "'Developer ID Application' (needs a paid Apple Developer Program membership)." >&2
      echo "Or publish an unsigned build now with: ALLOW_UNSIGNED=1 make release" >&2
      exit 1
  fi
else
  echo "==> Signing identity: $IDENTITY"
fi

# A distributable build starts from nothing. Incremental output is right for a dev loop, but
# what people install should not be linked against objects left by an earlier configuration —
# and a stale link is hard to spot, since the build reports success either way. Costs about
# nine seconds here, and nothing in CI, where the cache is empty regardless.
echo "==> Cleaning previous build output"
rm -rf .build

assemble_bundle

# 2. Sign with hardened runtime + secure timestamp (both required for notarization).
if [ "$NOTARIZE" = "1" ]; then
  echo "==> Code-signing (Developer ID, hardened runtime)"
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
else
  echo "==> Code-signing (ad-hoc)"
  SIGN_ARGS=(--force --sign -)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$MCP_NAME"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Notarize (zip, submit, wait for Apple's verdict).
ZIP="$APP_NAME.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
if [ "$NOTARIZE" = "1" ]; then
  echo "==> Submitting to Apple notary service — may take a few minutes"
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
      xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
      xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  fi

  # 4. Staple the ticket onto the app and confirm Gatekeeper accepts it.
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  echo "==> Gatekeeper assessment:"
  spctl -a -vvv -t install "$APP" || true
else
  echo "==> Skipping notarization (unsigned build)"
fi

# 5. Produce the distributable zip and update the Homebrew cask.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Done. Notarized, stapled: $APP"
else
  echo "==> Done. Ad-hoc signed, NOT notarized: $APP"
fi
echo "    artifact: $(pwd)/$ZIP"
echo "    version:  $SHORT_VERSION"
echo "    sha256:   $SHA"

# Update the cask in the sibling tap (override the path with TAP_CASK=…).
CASK="${TAP_CASK:-../homebrew-tokenration/Casks/tokenration.rb}"
if [ -f "$CASK" ]; then
  /usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$SHORT_VERSION\"/" "$CASK"
  /usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
  echo "==> Updated cask: $CASK"
else
  echo "==> Cask not found at $CASK — paste the version/sha256 above into your cask."
fi

cat <<NEXT

Release flow:
  1. Create a GitHub release tagged v$SHORT_VERSION on MilosRandelovic/tokenration and
   upload $ZIP to it.
  2. Commit & push the updated cask in the homebrew-tokenration tap.
NEXT
