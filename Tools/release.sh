#!/bin/zsh
# One-command release: version bump, clean build signed with the "Lasso Release" certificate, DMG,
# signature check, signed Sparkle update feed, GitHub release. Installed copies of Lasso pick it up
# on their own (Settings ▸ General ▸ Updates).
#
#   Tools/release.sh 0.16.0 notes.txt
#
# notes.txt: plain-text release notes. They become the GitHub release notes and are embedded in the
# update feed as plain text (Lasso shows update notes without a web view).
#
# Needs, on this Mac: the "Lasso Release" code-signing certificate in the login Keychain, the Sparkle
# update key as a file (~/.config/lasso-release/sparkle-ed25519.key, mode 600, exported once with
# `generate_keys --account lasso-app -x`; reading it from the Keychain pops a dialog for every new
# Sparkle binary), xcodegen, and gh signed in to GitHub.
# Builds from a fresh checkout of origin/main, so uncommitted work never ships.
set -euo pipefail

version=${1:?usage: Tools/release.sh <version> <notes.txt>}
notes=${2:?usage: Tools/release.sh <version> <notes.txt>}
[[ -f $notes ]] || { echo "No such notes file: $notes" >&2; exit 1; }
notes=$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")

repo=civarry/lasso-app
identity="Lasso Release"
sparkle_version=2.10.1
sparkle_sha256=$(sed -n 's/.*sha256 `\([0-9a-f]*\)`.*/\1/p' "$(git rev-parse --show-toplevel)/Vendor/README.md")
root=$(git rev-parse --show-toplevel)
edkey=${LASSO_UPDATE_KEY:-$HOME/.config/lasso-release/sparkle-ed25519.key}
[[ -r $edkey ]] || { echo "No update key at $edkey." >&2; exit 1; }

security find-identity -p codesigning | grep -q "\"$identity\"" \
  || { echo "The \"$identity\" signing certificate isn't in the Keychain." >&2; exit 1; }
if gh release view "v$version" -R "$repo" >/dev/null 2>&1; then
  echo "v$version is already released." >&2; exit 1
fi

# Sparkle's command-line tools, from the same pinned release as the vendored framework.
tools=~/Library/Caches/lasso-release/Sparkle-$sparkle_version
if [[ ! -x $tools/bin/generate_appcast ]]; then
  mkdir -p "$tools"
  gh release download "$sparkle_version" -R sparkle-project/Sparkle -p "Sparkle-$sparkle_version.tar.xz" -D "$tools" --clobber
  echo "$sparkle_sha256  $tools/Sparkle-$sparkle_version.tar.xz" | shasum -a 256 -c - >/dev/null \
    || { echo "Sparkle archive checksum mismatch." >&2; rm -rf "$tools"; exit 1; }
  tar -xf "$tools/Sparkle-$sparkle_version.tar.xz" -C "$tools"
fi

work=$(mktemp -d)
trap 'cd "$root"; git worktree remove --force "$work/src" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
git -C "$root" fetch -q origin
git -C "$root" worktree add -q "$work/src" origin/main
cd "$work/src"
[[ -f "$root/Config/Signing.local.xcconfig" ]] && cp "$root/Config/Signing.local.xcconfig" Config/

build=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$version\"/; s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$build\"/" project.yml
xcodegen generate -q
Tools/pin-packages.sh
git -c user.email=108951259+civarry@users.noreply.github.com commit -q -am "Release $version"

echo "Building $version ($build)…"
xcodebuild -scheme Lasso -configuration Release -derivedDataPath "$work/dd" -skipMacroValidation \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build \
  > "$work/build.log" 2>&1 || { tail -30 "$work/build.log" >&2; exit 1; }
app="$work/dd/Build/Products/Release/Lasso.app"

stage="$work/stage"; mkdir -p "$stage" "$root/dist"
cp -R "$app" "$stage/" && ln -s /Applications "$stage/Applications"
dmg="$root/dist/Lasso-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname Lasso -srcfolder "$stage" -format UDZO "$dmg"
"$root/Tools/check-signature.sh" "$dmg"

# The update feed: one item, this version, signed with the update key; notes embedded as plain text.
feed="$work/feed"; mkdir -p "$feed"
cp "$dmg" "$feed/"
cp "$notes" "$feed/Lasso-$version.txt"
"$tools/bin/generate_appcast" --ed-key-file "$edkey" --embed-release-notes \
  --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  -o "$feed/appcast.xml" "$feed"
grep -q 'sparkle:edSignature' "$feed/appcast.xml" || { echo "Feed isn't signed." >&2; exit 1; }
grep -q 'sparkle:format="plain-text"' "$feed/appcast.xml" || { echo "Notes aren't plain text." >&2; exit 1; }
codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q disable-library-validation \
  || { echo "Missing disable-library-validation: Sparkle wouldn't load." >&2; exit 1; }

git push -q origin HEAD:main
gh release create "v$version" -R "$repo" --title "Lasso $version" --notes-file "$notes" --latest \
  --target "$(git rev-parse HEAD)" "$dmg" "$feed/appcast.xml"
echo "Released Lasso $version ($build): https://github.com/$repo/releases/tag/v$version"
