#!/bin/zsh
# Puts the committed package versions (Config/Package.resolved) into the generated Xcode project, so a
# build uses exactly the versions that were tested instead of the newest that match project.yml.
# Run after `xcodegen generate`. After changing a package in project.yml, resolve in Xcode (or with
# `xcodebuild -resolvePackageDependencies`) and copy the new Package.resolved back to Config/.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=Lasso.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$dest"
cp Config/Package.resolved "$dest/Package.resolved"
