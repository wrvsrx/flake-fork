#!/usr/bin/env bash

set -euo pipefail

project_root=$(git rev-parse --show-toplevel)
binary="$project_root/scripts/UpdateAllExternals/.lake/build/bin/updateallexternals"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

git_init() {
  git -C "$1" init -q
  git -C "$1" config user.name Test
  git -C "$1" config user.email test@example.invalid
}

mkdir "$fixture/upstream-work"
git_init "$fixture/upstream-work"
printf 'base\n' >"$fixture/upstream-work/base"
git -C "$fixture/upstream-work" add base
git -C "$fixture/upstream-work" commit -qm 'base'
git -C "$fixture/upstream-work" branch -M main
git clone -q --bare "$fixture/upstream-work" "$fixture/upstream.git"

git clone -q "$fixture/upstream.git" "$fixture/patched-work"
git -C "$fixture/patched-work" config user.name Test
git -C "$fixture/patched-work" config user.email test@example.invalid
git -C "$fixture/patched-work" remote rename origin upstream
git -C "$fixture/patched-work" checkout -qb patched-main
printf 'patch\n' >"$fixture/patched-work/patch"
git -C "$fixture/patched-work" add patch
git -C "$fixture/patched-work" commit -qm 'custom patch'
git clone -q --bare "$fixture/patched-work" "$fixture/origin.git"
git -C "$fixture/origin.git" symbolic-ref HEAD refs/heads/patched-main
base_tip=$(git -C "$fixture/upstream-work" rev-parse HEAD)
git -C "$fixture/origin.git" tag tag_rebase-007 "$base_tip"
git -C "$fixture/patched-work" remote add origin "$fixture/origin.git"
git -C "$fixture/patched-work" push -q origin patched-main

git -C "$fixture/upstream-work" remote add origin "$fixture/upstream.git"
printf 'upstream\n' >"$fixture/upstream-work/upstream"
git -C "$fixture/upstream-work" add upstream
git -C "$fixture/upstream-work" commit -qm 'upstream update'
git -C "$fixture/upstream-work" push -q origin main

mkdir "$fixture/parent"
git_init "$fixture/parent"
git -C "$fixture/parent" -c protocol.file.allow=always submodule add -q "$fixture/origin.git" externals/test
git -C "$fixture/parent/externals/test" config user.name Test
git -C "$fixture/parent/externals/test" config user.email test@example.invalid
printf 'tracked\n' >"$fixture/parent/tracked"
git -C "$fixture/parent" add tracked
git -C "$fixture/parent" commit -qm 'add fixture'
printf 'staged change\n' >"$fixture/parent/tracked"
git -C "$fixture/parent" add tracked
printf 'unrelated\n' >"$fixture/parent/unrelated"

(
  cd "$fixture/parent"
  "$binary" --repo test "$fixture/upstream.git" main patched-main
)

old_tip=$(git -C "$fixture/patched-work" rev-parse patched-main)
test "$(git -C "$fixture/origin.git" rev-parse refs/tags/tag_rebase-008)" = "$old_tip"
test "$(git -C "$fixture/parent" log -1 --format=%s)" = 'chore(externals/test): update it'
test -f "$fixture/parent/unrelated"
test -z "$(git -C "$fixture/parent" ls-files --error-unmatch unrelated 2>/dev/null || true)"
test "$(git -C "$fixture/parent" show HEAD:tracked)" = tracked
test "$(git -C "$fixture/parent" show :tracked)" = 'staged change'

# Simulate interruption after the child push but before the parent gitlink commit.
printf 'upstream 2\n' >>"$fixture/upstream-work/upstream"
git -C "$fixture/upstream-work" commit -qam 'second upstream update'
git -C "$fixture/upstream-work" push -q origin main
git -C "$fixture/parent/externals/test" fetch -q upstream main
git -C "$fixture/parent/externals/test" rebase -q FETCH_HEAD
git -C "$fixture/parent/externals/test" push -q --force-with-lease origin HEAD:patched-main

(
  cd "$fixture/parent"
  "$binary" --repo test "$fixture/upstream.git" main patched-main
)

test "$(git -C "$fixture/parent" log -1 --format=%s)" = 'chore(externals/test): update it'
git -C "$fixture/parent" diff --quiet HEAD -- externals/test
test "$(git -C "$fixture/parent" show HEAD:tracked)" = tracked
test "$(git -C "$fixture/parent" show :tracked)" = 'staged change'

# A changed patch stack must never trigger the automatic force-push path.
remote_before=$(git -C "$fixture/origin.git" rev-parse patched-main)
printf 'changed patch\n' >>"$fixture/parent/externals/test/patch"
git -C "$fixture/parent/externals/test" commit -qam 'custom patch'
printf 'upstream 3\n' >>"$fixture/upstream-work/upstream"
git -C "$fixture/upstream-work" commit -qam 'third upstream update'
git -C "$fixture/upstream-work" push -q origin main
if (
  cd "$fixture/parent"
  "$binary" --repo test "$fixture/upstream.git" main patched-main
); then
  printf 'changed patch stack was unexpectedly accepted\n' >&2
  exit 1
fi
test "$(git -C "$fixture/origin.git" rev-parse patched-main)" = "$remote_before"
test -z "$(git -C "$fixture/origin.git" tag --list tag_rebase-009)"
printf 'integration tests passed\n'
