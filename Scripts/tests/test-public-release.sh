#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/Scripts/public-release.sh"

build_line="$(grep -nF 'SKIP_LOCAL_INSTALL=1 "$ROOT/Scripts/release.sh"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
push_line="$(grep -nF 'git push -u origin "${BRANCH}"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"

if [[ -z "$build_line" ]]; then
  echo "FAIL: make public does not build fresh local release artifacts" >&2
  exit 1
fi
if [[ -z "$push_line" || "$build_line" -ge "$push_line" ]]; then
  echo "FAIL: local release artifacts must be built before the public tag is pushed" >&2
  exit 1
fi

echo "PASS: make public builds local release artifacts before publishing"

# Run the real release entry point against disposable repositories. Only fixture
# Git history is real; every network command and the expensive build are mocked.
REAL_GIT="$(command -v git)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localclip-public-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  fetch|ls-remote) exit 0 ;;
  push)
    if [[ "${2:-}" == -u && "${3:-}" == origin ]]; then
      printf 'push-branch %s\n' "$("$PUBLIC_TEST_REAL_GIT" rev-parse HEAD)" >> "$PUBLIC_TEST_LOG"
    elif [[ "${2:-}" == origin && "${3:-}" == v* ]]; then
      printf 'push-tag %s\n' "$3" >> "$PUBLIC_TEST_LOG"
    else
      echo "unexpected mocked git push: $*" >&2
      exit 90
    fi
    exit 0
    ;;
  tag)
    if [[ "${2:-}" == -a ]]; then
      printf 'create-tag %s %s\n' "${3:-}" "${4:-}" >> "$PUBLIC_TEST_LOG"
    fi
    ;;
esac
exec "$PUBLIC_TEST_REAL_GIT" "$@"
MOCK

cat > "$TEST_ROOT/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'run list')
    shift 2
    workflow='' branch='' commit='' limit='' json='' jq=''
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workflow) workflow="$2" ;;
        --branch) branch="$2" ;;
        --commit) commit="$2" ;;
        --limit) limit="$2" ;;
        --json) json="$2" ;;
        --jq) jq="$2" ;;
        *) echo "unexpected gh run list argument: $1" >&2; exit 91 ;;
      esac
      shift 2
    done
    expected="$(cat "$PUBLIC_TEST_COMMIT_FILE")"
    [[ "$workflow" == ci.yml && "$branch" == main && "$commit" == "$expected" && "$limit" == 1 \
       && "$json" == databaseId && "$jq" == '.[0].databaseId // empty' ]] || {
      echo "CI must query the exact committed candidate on main" >&2; exit 92;
    }
    printf 'ci-query %s\n' "$commit" >> "$PUBLIC_TEST_LOG"
    if [[ "$PUBLIC_TEST_CASE" != missing ]]; then echo 391; fi
    ;;
  'run watch')
    [[ "${3:-}" == 391 && " $* " == *' --exit-status '* ]] || exit 93
    echo 'ci-watch 391' >> "$PUBLIC_TEST_LOG"
    if [[ "$PUBLIC_TEST_CASE" == watch-failure ]]; then
      echo 'ci-watch-failed' >> "$PUBLIC_TEST_LOG"
      exit 1
    fi
    echo 'ci-watch-success' >> "$PUBLIC_TEST_LOG"
    ;;
  'run view')
    [[ "${3:-}" == 391 ]] || exit 94
    sha="$(cat "$PUBLIC_TEST_COMMIT_FILE")"
    conclusion=success
    if [[ "$PUBLIC_TEST_CASE" == wrong-sha ]]; then sha=0000000000000000000000000000000000000000; fi
    if [[ "$PUBLIC_TEST_CASE" == non-success ]]; then conclusion=cancelled; fi
    printf 'ci-view %s %s\n' "$sha" "$conclusion" >> "$PUBLIC_TEST_LOG"
    if [[ "$sha" == "$(cat "$PUBLIC_TEST_COMMIT_FILE")" && "$conclusion" == success ]]; then
      printf 'ci-validated %s\n' "$sha" >> "$PUBLIC_TEST_LOG"
    fi
    printf '%s %s\n' "$sha" "$conclusion"
    ;;
  'repo view') echo fixture/LocalClip ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 95 ;;
esac
MOCK

cat > "$TEST_ROOT/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'poll-sleep %s\n' "$*" >> "$PUBLIC_TEST_LOG"
MOCK
chmod +x "$TEST_ROOT/bin/git" "$TEST_ROOT/bin/gh" "$TEST_ROOT/bin/sleep"

fail_case() {
  echo "FAIL: $1" >&2
  if [[ -f "${case_output:-}" ]]; then cat "$case_output" >&2; fi
  if [[ -f "${case_log:-}" ]]; then cat "$case_log" >&2; fi
  exit 1
}

assert_order() {
  local first second
  first="$(grep -nF "$1" "$case_log" | head -1 | cut -d: -f1 || true)"
  second="$(grep -nF "$2" "$case_log" | head -1 | cut -d: -f1 || true)"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] \
    || fail_case "$scenario: expected '$1' before '$2'"
}

run_case() {
  local scenario="$1" repo case_log case_output commit_file initial_commit candidate status
  repo="$TEST_ROOT/$scenario"
  case_log="$TEST_ROOT/$scenario.events"
  case_output="$TEST_ROOT/$scenario.output"
  commit_file="$TEST_ROOT/$scenario.commit"
  mkdir -p "$repo/Scripts" "$repo/Resources"
  : > "$case_log"
  cp "$SCRIPT" "$repo/Scripts/public-release.sh"
  printf 'dist/\n' > "$repo/.gitignore"
  cat > "$repo/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
  cat > "$repo/Scripts/release.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SKIP_LOCAL_INSTALL:-}" == 1 ]] || exit 96
root="$(cd "$(dirname "$0")/.." && pwd)"
"$PUBLIC_TEST_REAL_GIT" -C "$root" rev-parse HEAD > "$PUBLIC_TEST_COMMIT_FILE"
printf 'build %s\n' "$(cat "$PUBLIC_TEST_COMMIT_FILE")" >> "$PUBLIC_TEST_LOG"
mkdir -p "$root/dist/LocalClip.app/Contents"
cp "$root/Resources/Info.plist" "$root/dist/LocalClip.app/Contents/Info.plist"
case "$PUBLIC_TEST_CASE" in
  build-head-changed) "$PUBLIC_TEST_REAL_GIT" -C "$root" commit --allow-empty -qm 'unexpected build commit' ;;
  build-dirty) printf '\n' >> "$root/Resources/Info.plist" ;;
esac
BUILD
  chmod +x "$repo/Scripts/release.sh"
  "$REAL_GIT" init -q "$repo"
  "$REAL_GIT" -C "$repo" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$repo" config user.name 'LocalClip release test'
  "$REAL_GIT" -C "$repo" config user.email 'release-test@example.invalid'
  "$REAL_GIT" -C "$repo" config commit.gpgsign false
  "$REAL_GIT" -C "$repo" config tag.gpgsign false
  "$REAL_GIT" -C "$repo" config core.hooksPath /dev/null
  "$REAL_GIT" -C "$repo" remote add origin https://example.invalid/fixture/LocalClip.git
  "$REAL_GIT" -C "$repo" add .
  "$REAL_GIT" -C "$repo" commit -qm 'fixture baseline'
  initial_commit="$("$REAL_GIT" -C "$repo" rev-parse HEAD)"
  if env PATH="$TEST_ROOT/bin:$PATH" PUBLIC_TEST_REAL_GIT="$REAL_GIT" \
      PUBLIC_TEST_CASE="$scenario" PUBLIC_TEST_LOG="$case_log" PUBLIC_TEST_COMMIT_FILE="$commit_file" \
      VERSION=9.8.7 bash "$repo/Scripts/public-release.sh" > "$case_output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [[ -s "$commit_file" ]] || fail_case "$scenario: never built the candidate"
  candidate="$(cat "$commit_file")"
  [[ "$candidate" != "$initial_commit" ]] || fail_case "$scenario: version bump did not create a candidate commit"

  if [[ "$scenario" == success ]]; then
    [[ "$status" == 0 ]] || fail_case 'successful candidate CI prevented publication'
    [[ "$("$REAL_GIT" -C "$repo" rev-parse 'v9.8.7^{commit}')" == "$candidate" ]] \
      || fail_case 'release tag targets a different commit than successful CI'
    [[ "$("$REAL_GIT" -C "$repo" cat-file -t refs/tags/v9.8.7)" == tag ]] \
      || fail_case 'release tag must be annotated'
    grep -qF "create-tag v9.8.7 $candidate" "$case_log" || fail_case 'tag command did not pin the candidate SHA'
    assert_order "build $candidate" "push-branch $candidate"
    assert_order "push-branch $candidate" "ci-query $candidate"
    assert_order 'ci-query ' 'ci-watch-success'
    assert_order 'ci-watch-success' "ci-validated $candidate"
    assert_order "ci-validated $candidate" 'create-tag '
    assert_order 'create-tag ' 'push-tag v9.8.7'
  else
    [[ "$status" != 0 ]] || fail_case "$scenario: unsafe publication unexpectedly succeeded"
    [[ -z "$("$REAL_GIT" -C "$repo" tag -l)" ]] || fail_case "$scenario: created a release tag"
    if grep -qE '^(create-tag|push-tag) ' "$case_log"; then fail_case "$scenario: attempted to publish a release tag"; fi
    case "$scenario" in
      build-head-changed|build-dirty)
        if grep -qE '^(push-branch|ci-query) ' "$case_log"; then fail_case "$scenario: pushed an invalid candidate"; fi
        ;;
      *)
        assert_order "build $candidate" "push-branch $candidate"
        assert_order "push-branch $candidate" "ci-query $candidate"
        case "$scenario" in
          watch-failure) grep -qF ci-watch-failed "$case_log" || fail_case 'CI watch failure was not exercised' ;;
          missing)
            [[ "$(grep -cF 'ci-query ' "$case_log")" == 30 ]] || fail_case 'missing CI must exhaust the bounded 30 lookups'
            if grep -qF ci-watch "$case_log"; then fail_case 'missing CI was watched anyway'; fi
            ;;
          wrong-sha) grep -qF 'ci-view 0000000000000000000000000000000000000000 success' "$case_log" || fail_case 'CI SHA mismatch was not exercised' ;;
          non-success) grep -qF "ci-view $candidate cancelled" "$case_log" || fail_case 'CI conclusion mismatch was not exercised' ;;
        esac
        ;;
    esac
  fi
  echo "PASS: release CI gate ($scenario)"
}

for scenario in success watch-failure missing wrong-sha non-success build-head-changed build-dirty; do
  run_case "$scenario"
done
