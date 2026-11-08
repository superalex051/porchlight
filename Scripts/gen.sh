#!/usr/bin/env bash
# Generates PorchLight.xcodeproj from project.yml.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec xcodegen generate --spec project.yml
