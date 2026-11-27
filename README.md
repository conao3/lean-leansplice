# leansplice

Leansplice is a dependency-free Lean 4 library and CLI for parsing, rendering,
generating, and strictly applying unified diffs to a single UTF-8 text file.

## Try the CLI

With Nix:

```sh
nix run github:conao3/lean-leansplice -- diff old.txt new.txt > change.patch
nix run github:conao3/lean-leansplice -- apply change.patch old.txt
```

Or clone the repository and build with [elan](https://github.com/leanprover/elan).
Elan reads the pinned version from `lean-toolchain`.

```sh
git clone https://github.com/conao3/lean-leansplice.git
cd lean-leansplice
lake build
.lake/build/bin/leansplice diff old.txt new.txt > change.patch
.lake/build/bin/leansplice apply change.patch old.txt > result.txt
```

`apply` reads the named source file and prints the result without modifying it.
If the patch is rejected, it prints a diagnostic to stderr and exits nonzero
without printing partial output. Both commands exit nonzero on output errors.
`diff` uses the labels `a/file` and `b/file`; it prints an empty patch when the
inputs are identical.

## Lean API

To use the library from a Lake project, add this to your `lakefile.toml` (use the
same Lean version as leansplice):

```toml
[[require]]
name = "leansplice"
git = "https://github.com/conao3/lean-leansplice.git"
rev = "main"
```

```lean
import Leansplice

def patchText := Leansplice.render (Leansplice.diff "old\n" "new\n")

def result : Except Leansplice.Error String := do
  let patch ← Leansplice.parse patchText
  Leansplice.apply patch "old\n"

#eval result -- Except.ok "new\n"
```

`Leansplice.diff` accepts optional `oldFile`, `newFile`, and `context`
arguments. Use nonempty labels without LF or tabs. The default context is three lines,
and nearby edits share a hunk.

## Supported patches

- One file, with `---` and `+++` headers, unified hunks, and an optional standard
  Git text prelude. Mode changes accompanying text hunks are ignored.
  Tab-separated timestamps after file labels are stripped. Rendering adds a
  tab delimiter after labels that contain spaces. Labels otherwise keep their
  original spelling and are never used to look up files.
- Line ranges may omit a count of one. Application checks both hunk
  coordinates, all context and removal lines, and their LF status; it never
  relocates a hunk. Bare empty lines within a hunk count as blank context.
  Text outside the hunks is copied as-is.
- The patch uses LF separators. CRs in file content and Git's
  `\ No newline at end of file` markers are preserved. An empty patch is a
  no-op; Git creation and deletion patches are applied to and from empty text.
- Binary, multi-file, rename, and mode-only patches are out of scope. There is
  no fuzz matching, three-way merge, or file writing in the library.

## Development

```sh
nix develop --command make check
nix build
```

With elan and Git on your PATH, `make check` also runs directly. It runs
`lake build`, `lake test` (golden and round-trip tests), and a differential
test that applies Git-generated patches with leansplice, then applies
leansplice-generated patches with `git apply`.

## Diff benchmark

Diff generation trims common edges and uses Myers' shortest edit script for
small edit distances. If the search exceeds 64 insertions and deletions, it
pairs occurrences of each line in order and keeps the longest increasing
chain of pairs. This avoids rescanning repeated lines; the fallback can
produce a larger patch than a globally shortest edit script.

To compare with the pre-change version, build its CLI in a separate worktree
and pass that executable to `make bench`:

```sh
git worktree add --detach ../leansplice-baseline 65aa67d
baseline="$(nix build path:../leansplice-baseline --no-link --print-out-paths)"
nix develop --command make bench BASELINE="$baseline/bin/leansplice"
```

The benchmark times the native `diff` CLI, including file reads and patch
rendering. It reports the median of five runs and checks the generated patch
with strict application before timing each case.

Example results on x86-64 Linux (Intel Xeon, Lean 4.36.0):

| Input | Before | After |
| --- | ---: | ---: |
| 8,000 changed records alternating with 8,000 identical separators | 21.136 s | 0.063 s |
| 100,000 lines with three replacements | 0.313 s | 0.141 s |

Licensed under Apache-2.0.
