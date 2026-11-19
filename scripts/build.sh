#!/usr/bin/env bash
# Builds build/Strata.app.
#
# Signs with $STRATA_SIGNING_IDENTITY, else the first "Developer ID Application" identity in your keychain, else ad-hoc.
# A stable signature matters: macOS ties privacy grants (Desktop, Documents, Full Disk Access) to it, so ad-hoc builds
# ask again after every rebuild.
#
#   scripts/build.sh            # release
#   scripts/build.sh debug
#   scripts/build.sh release --open
#
# Release builds (.github/workflows/release.yml) also set:
#   STRATA_VERSION, STRATA_BUILD_NUMBER   stamped into Info.plist (version like 1.2.3, build number digits)
#   STRATA_KEYCHAIN                       the keychain holding the signing identity
#   STRATA_TIMESTAMP=1                    a secure timestamp on the signature, which notarization requires
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
# Checked before anything is built or removed.
if [[ -n "${STRATA_VERSION:-}" && ! "$STRATA_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "STRATA_VERSION must look like 1.2.3" >&2; exit 1
fi
if [[ -n "${STRATA_BUILD_NUMBER:-}" && ! "$STRATA_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "STRATA_BUILD_NUMBER must be digits" >&2; exit 1
fi
swift build -c "$config" --arch arm64 --product Strata
swift build -c "$config" --arch arm64 --product StrataCLI
swift build -c "$config" --arch arm64 --product StrataArchiveService
swift build -c "$config" --arch arm64 --product StrataTableWorker
swift build -c "$config" --arch arm64 --product StrataMediaWorker
swift build -c "$config" --arch arm64 --product StrataArchiveWorker
swift build -c "$config" --arch arm64 --product StrataResourceCheck
bins="$(swift build -c "$config" --arch arm64 --show-bin-path)"

app=build/Strata.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bins/Strata" "$app/Contents/MacOS/Strata"
# The command-line tool lives in Helpers: "strata" would clash with "Strata" in MacOS on a case-insensitive disk.
cp "$bins/StrataCLI" "$app/Contents/Helpers/strata"
# Ship the preview resources so they can be found away from the checkout.
cp -R "$bins/Strata_StrataPreviews.bundle" "$app/Contents/Resources/Strata_StrataPreviews.bundle"
python3 scripts/check-app-resources.py "$app" "$bins/StrataResourceCheck" Tests/PreviewDocuments/07-Issue36-Mermaid.md
# Credits for the third-party software Strata includes or builds on travel with the app.
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${STRATA_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $STRATA_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${STRATA_BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $STRATA_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
python3 scripts/build-icon.py "$app/Contents/Resources" "$app/Contents/Info.plist"

# Translations: every Localization/<code>.json becomes <code>.lproj (untranslated strings fall back to English), and
# the bundle lists the languages it has. Adding a language file is all it takes.
if [[ -f Localization/en.json ]]; then
  codes=$(python3 scripts/localize.py build "$app/Contents/Resources")
  plist="$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleLocalizations" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$plist"
  for code in ${codes//,/ }; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $code" "$plist"
  done
  /usr/libexec/PlistBuddy -c "Delete :CFBundleDevelopmentRegion" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$plist"
fi

identity="${STRATA_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
identity="${identity:--}"
sign_options=(--force --options runtime)
if [[ -n "${STRATA_KEYCHAIN:-}" ]]; then sign_options+=(--keychain "$STRATA_KEYCHAIN"); fi
if [[ "${STRATA_TIMESTAMP:-}" == 1 && "$identity" != - ]]; then sign_options+=(--timestamp); fi
sign=("${sign_options[@]}" --sign "$identity")
# Sign the helpers and the archive service before sealing the app bundle.
codesign "${sign[@]}" "$app/Contents/Helpers/strata" >/dev/null
# Archives are read in an XPC service with an App Sandbox of its own, by a worker per read that inherits it: neither can
# reach your files, the network or devices, and both refuse to read without their entitlements. macOS ties a sandbox
# container to the signature that made it, and a build signed another way can take it over: only distribution builds
# (STRATA_VERSION) use the shipped service identifier, so a local build never touches an installed Strata's container.
local_identifier=""
if [[ -z "${STRATA_VERSION:-}" ]]; then local_identifier=dev.strata.app.local.ArchiveService; fi
scripts/archive-service.sh "$app" "$bins" --identifier "$local_identifier" \
  --service-entitlements Sources/StrataArchiveService/ArchiveService.entitlements \
  --worker-entitlements Sources/StrataArchiveWorker/ArchiveWorker.entitlements -- "${sign[@]}"
codesign "${sign[@]}" "$app" >/dev/null
if [[ "$identity" == - ]]; then signer="ad-hoc"; else signer="Developer ID"; fi
echo "Built $app ($config, signed $signer)"

if [[ "${2:-}" == "--open" ]]; then
  # Quit the running copy and wait for it to exit, so `open` launches this build instead of reactivating the old one.
  osascript -e 'tell application id "dev.strata.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -x Strata >/dev/null || break; sleep 0.1; done
  pkill -x Strata 2>/dev/null || true
  while pgrep -x Strata >/dev/null; do sleep 0.1; done
  open "$app"
fi
