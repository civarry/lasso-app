#!/bin/zsh
# Builds lasso-pkg from Lasso's own package engine, so it checks and runs packages exactly as Lasso
# does. Needs only the Xcode command-line tools (swiftc), so the catalog's CI can build it too.
#
#   Tools/lasso-pkg/build.sh [output]     # default: .build/lasso-pkg
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-$root/.build/lasso-pkg}
mkdir -p "$(dirname "$out")"
version=$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' "$root/project.yml")
generated=$(mktemp -d)
trap 'rm -rf "$generated"' EXIT
print "enum LassoPkgVersion { static let lasso = \"$version\" }" > "$generated/Version.swift"
engine=(PackageManifest PackageTemplate PackagePatches BuiltInContent PackageHTTP PackageScript PackageShortcut
        PackageRequirements PackageFiles PackageStarters)
swiftc -O -swift-version 6 -parse-as-library -module-name lasso_pkg -o "$out" \
  "$root"/Tools/lasso-pkg/main.swift "$root"/Tools/lasso-pkg/Shims.swift "$generated/Version.swift" \
  $(for f in $engine; print "$root/Lasso/Packages/$f.swift")
print "Built $out (Lasso $version)"
