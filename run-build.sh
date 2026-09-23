#!/usr/bin/env bash
set -euo pipefail

source_sha="${1:?Expected application commit}"
result_dir="${2:?Output directory}"
tooling_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$tooling_dir/source"
cd "$source_dir"

bash CodexMobile/scripts/check-source-revision.sh "$source_sha"
xcodebuild -version
xcrun --find swiftc
npm ci --ignore-scripts --prefix phodex-bridge
npm ci --ignore-scripts --prefix relay
npm test --prefix phodex-bridge
npm run check:sdk --prefix phodex-bridge
npm run check:native --prefix phodex-bridge
npm run check:package --prefix phodex-bridge
npm test --prefix relay
bash CodexMobile/scripts/check-markdown-append-correctness.sh
python3 -B -m unittest discover -s CodexMobile/scripts -p 'test_verify_unsigned_ipa.py'

xcodebuild \
  -project "$source_dir/CodexMobile/CodexMobile.xcodeproj" \
  -scheme CodexMobile -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$RUNNER_TEMP/remodex-compile" \
  build-for-testing ARCHS=arm64 ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) REMODEX_PERFORMANCE_TESTING' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

products="$RUNNER_TEMP/remodex-compile/Build/Products"
for product in CodexMobile.app CodexMobileTests.xctest CodexMobileUITests.xctest RemodexWidget.appex; do
  test -n "$(find "$products" -type d -name "$product" -print -quit)"
done

xcodebuild \
  -project "$source_dir/CodexMobile/CodexMobile.xcodeproj" \
  -scheme RemodexMenuBar -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$RUNNER_TEMP/remodex-menu-compile" \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
test -d "$RUNNER_TEMP/remodex-menu-compile/Build/Products/Release/RemodexMenuBar.app"

bash CodexMobile/scripts/check-source-revision.sh "$source_sha"
bash CodexMobile/scripts/build-unsigned-ipa.sh "$source_sha"
cp build/unsigned-ipa/remodex-unsigned-release.ipa "$result_dir/"
cp build/unsigned-ipa/build-metadata.json "$result_dir/"
