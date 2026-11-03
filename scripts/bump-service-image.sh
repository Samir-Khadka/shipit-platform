#!/usr/bin/env bash
# Bump an onboarded external service's image tag in k8s/services/.
#
# Used when a service repo's CI can't bump ShipIt itself (no SHIPIT_BUMP_PAT
# secret set) — run this after the service's shipit-publish workflow pushes
# a new :<sha> image to GHCR, then commit + push the result.
#
# Usage: ./scripts/bump-service-image.sh <image-name> <new-sha>
# Example: ./scripts/bump-service-image.sh messaging-api abc123def456...
#
# Known image names: taskboard-devops-api, taskboard-devops-web,
# messaging-api, suraksha.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <image-name> <new-sha>" >&2
  exit 1
fi

IMG="$1"
SHA="$2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "refusing: '$SHA' is not a 40-char commit SHA" >&2
  exit 1
fi

# Same sed shape as the in-repo tag-bump: rewrite everything after the colon
# on the matching image line, across all onboarded services.
grep -rl "image: ghcr.io/samir-khadka/${IMG}:" "${REPO_ROOT}/k8s/services/" \
  | xargs sed -i -E "s#(image: ghcr.io/samir-khadka/${IMG}:)[^[:space:]]+#\1${SHA}#"

echo "bumped ghcr.io/samir-khadka/${IMG} to ${SHA} in k8s/services/"
grep -rn "image: ghcr.io/samir-khadka/${IMG}:" "${REPO_ROOT}/k8s/services/"
