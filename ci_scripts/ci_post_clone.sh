#!/bin/sh
# Xcode Cloud: regenerate the gitignored Continuity.xcodeproj before the build.
# Scripts run with cwd = ci_scripts/; hop to the clone root first.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Installing XcodeGen..."
brew install xcodegen

echo "Generating Continuity.xcodeproj from project.yml..."
xcodegen generate

ls -la Continuity.xcodeproj
