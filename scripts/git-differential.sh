#!/usr/bin/env bash
set -euo pipefail
ulimit -s 65536

splice="$(pwd)/.lake/build/bin/leansplice"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q

check() {
  local name="$1" old="$2" new="$3" status=0
  printf '%s' "$old" > file
  printf '%s' "$new" > expected

  git diff --no-index --no-ext-diff --no-color --text -- file expected > git.patch || status=$?
  if [[ "$status" != 1 ]]; then
    printf 'git diff failed for %s: expected 1, got %s\n' "$name" "$status" >&2
    exit 1
  fi
  "$splice" apply git.patch file > result
  cmp expected result

  "$splice" diff file expected > splice.patch
  git apply splice.patch
  cmp expected file
  printf 'Git interoperability: %s\n' "$name"
}

check replacement $'before\nold\nafter\n' $'before\nnew\nafter\n'
check both-no-final-lf $'before\nold' $'before\nnew'
check add-final-lf $'before\nsame' $'before\nsame\n'
check remove-final-lf $'before\nsame\n' $'before\nsame'
check unterminated-context $'old\nend' $'new\nend'
check blank-and-unicode $'begin\n\né\nend\n' $'begin\n\n文\nend\n'
check crlf $'old\r\nend\r\n' $'new\r\nend\r\n'
check multiple-hunks $'old\n1\n2\n3\n4\n5\n6\n7\nremove\nend\n' \
  $'new\nextra\n1\n2\n3\n4\n5\n6\n7\nend\n'
check empty-source '' $'one\n'
check empty-target $'one\n' ''

printf 'created\n' > expected
status=0
git diff --no-index --no-ext-diff --no-color -- /dev/null expected > git.patch || status=$?
test "$status" -eq 1
touch empty
"$splice" apply git.patch empty > result
cmp expected result

status=0
git diff --no-index --no-ext-diff --no-color -- expected /dev/null > git.patch || status=$?
test "$status" -eq 1
"$splice" apply git.patch expected > result
cmp empty result
printf 'Git interoperability: creation and deletion headers\n'

if [[ -c /dev/full ]]; then
  check_output_failure() {
    local status=0 diagnostic
    "$splice" "$@" >/dev/full 2>output-error || status=$?
    test "$status" -eq 1
    read -r diagnostic < output-error
    [[ "$diagnostic" == leansplice:* ]]
    printf 'CLI reports stdout failure: %s\n' "$1"
  }

  "$splice" diff empty expected > splice.patch
  check_output_failure diff empty expected
  check_output_failure apply splice.patch empty
fi
