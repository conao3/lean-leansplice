#!/usr/bin/env bash
set -euo pipefail
ulimit -s 65536

baseline="${1:-}"
current="$PWD/.lake/build/bin/leansplice"
if [[ -n "$baseline" && ! -x "$baseline" ]]; then
  printf 'Not an executable baseline: %s\n' "$baseline" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
old="$work/old"
new="$work/new"
TIMEFORMAT='%3R'

measure() {
  local binary="$1"
  "$binary" diff "$old" "$new" > "$work/change.patch" || return
  "$binary" apply "$work/change.patch" "$old" > "$work/applied" || return
  cmp "$work/applied" "$new" || return
  for _ in {1..5}; do
    { time "$binary" diff "$old" "$new" > /dev/null; } 2>&1 || return
  done | LC_ALL=C sort -n | sed -n '3p'
}

report() {
  local name="$1" before='-' after
  if [[ -n "$baseline" ]]; then before="$(measure "$baseline")" || return; fi
  after="$(measure "$current")" || return
  printf '%-32s %10s %10s\n' "$name" "$before" "$after"
}

export LC_ALL=C
printf '%-32s %10s %10s\n' 'Case (median seconds, 5 runs)' 'baseline' 'current'
awk 'BEGIN { for (i=0; i<8000; i++) printf "old %d\n---\n", i }' > "$old"
awk 'BEGIN { for (i=0; i<8000; i++) printf "new %d\n---\n", i }' > "$new"
report 'Repeated separators (16k lines)'

awk 'BEGIN { for (i=0; i<100000; i++) printf "line %d\n", i }' > "$old"
awk 'BEGIN {
  for (i=0; i<100000; i++) {
    if (i == 25000 || i == 50000 || i == 75000) printf "changed %d\n", i
    else printf "line %d\n", i
  }
}' > "$new"
report 'Mostly equal (100k lines)'
