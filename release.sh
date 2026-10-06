#!/usr/bin/env bash
# Releases bacnet_plugin: sets the version in pubspec.yaml and README.md,
# dates its CHANGELOG section (other "Unreleased" sections are marked as
# part of this release), commits and pushes main, waits for CI and pushes
# the tag v<version>, which publishes the package to pub.dev (CI/CD).
#
# Usage: ./release.sh <version> [--date YYYY-MM-DD] [--check] [--no-wait]
#                    [--dry-run]
#   --date     release date (default: today)
#   --check    run tool/check_package.dart before tagging
#   --no-wait  do not wait for CI on main (asks instead when gh is missing)
#   --dry-run  only show the changes, commit and push nothing
#
# Example: ./release.sh 0.8.0
set -euo pipefail

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

version=""
date=$(date +%F)
check=false
wait_ci=true
dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --date) date="${2:?--date needs a value}"; shift 2 ;;
    --check) check=true; shift ;;
    --no-wait) wait_ci=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option $1" >&2; usage 64 ;;
    *) [ -z "$version" ] || usage 64; version="$1"; shift ;;
  esac
done
[ -n "$version" ] || usage 64

fail() { echo "error: $*" >&2; exit 1; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] ||
  fail "\"$version\" is not a version (x.y.z)"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
  fail "\"$date\" is not a date (YYYY-MM-DD)"
tag="v$version"

cd "$(git rev-parse --show-toplevel)"
[ -f pubspec.yaml ] && grep -q '^name: bacnet_plugin$' pubspec.yaml ||
  fail "run it inside the bacnet_plugin repository"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "check out main first"
[ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"

echo "==> updating main"
git fetch origin main --tags
git merge --ff-only origin/main
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null ||
  [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
  fail "tag $tag exists already"
fi

grep -q "^## \[$version\] - " CHANGELOG.md ||
  fail "CHANGELOG.md has no section \"## [$version] - Unreleased\""

echo "==> setting version $version ($date)"
# perl: the same in-place edit on Linux, macOS and Git Bash
V="$version" D="$date" perl -pi -e '
  s/^version: .*$/version: $ENV{V}/;
' pubspec.yaml
V="$version" perl -pi -e '
  s/^(\s*bacnet_plugin: \^)[0-9][0-9A-Za-z.+-]*$/$1$ENV{V}/;
' README.md
V="$version" D="$date" perl -pi -e '
  if (/^## \[\Q$ENV{V}\E\] - /) {
    $_ = "## [$ENV{V}] - $ENV{D}\n";
  } elsif (/^## \[([^\]]+)\] - Unreleased\s*$/) {
    $_ = "## [$1] - not published separately (in $ENV{V})\n";
  }
' CHANGELOG.md

git --no-pager diff --stat
git --no-pager diff -U0 -- pubspec.yaml README.md CHANGELOG.md | grep '^[+-][^+-]' || true

if $dry_run; then
  git checkout -- pubspec.yaml README.md CHANGELOG.md
  echo "==> dry run: nothing committed"
  exit 0
fi

if $check; then
  echo "==> checking the published package"
  dart run tool/check_package.dart
fi

if [ -n "$(git status --porcelain)" ]; then
  git commit -qam "chore: release $version"
  echo "==> pushing main"
  git push origin main
else
  echo "==> versions already set, nothing to commit"
fi
sha=$(git rev-parse HEAD)

if $wait_ci && command -v gh >/dev/null; then
  echo "==> waiting for CI on $sha"
  run=""
  for _ in $(seq 1 30); do
    run=$(gh run list --workflow ci.yml --branch main --commit "$sha" \
      --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    [ -n "$run" ] && break
    sleep 10
  done
  [ -n "$run" ] || fail "no CI run for $sha; tag it yourself when CI is green"
  gh run watch "$run" --exit-status ||
    fail "CI failed on main: fix it, then run this script again"
else
  read -r -p "Is CI green on main ($sha)? Tag $tag now? [y/N] " answer
  [[ "$answer" =~ ^[Yy] ]] || { echo "not tagged"; exit 0; }
fi

echo "==> tagging $tag"
git tag -a "$tag" -m "bacnet_plugin $version"
git push origin "$tag"
remote=$(git remote get-url origin | sed -E 's#(git@|https://)github.com[:/]##; s#\.git$##')
echo "==> $tag pushed: CI/CD publishes it to pub.dev"
echo "    https://github.com/$remote/actions"