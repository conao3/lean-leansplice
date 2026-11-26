import Leansplice

open Leansplice

def check [BEq α] [Repr α] (name : String) (actual expected : α) : IO Unit := do
  unless actual == expected do
    throw (IO.userError s!"{name}: expected {repr expected}, got {repr actual}")

def unwrap (result : Except Error α) : IO α :=
  match result with
  | .ok value => pure value
  | .error error => throw (IO.userError (toString error))

def reject (name : String) (result : Except Error α) : IO Unit := do
  if let .ok _ := result then
    throw (IO.userError s!"{name}: expected rejection")

def malformed (name patch : String) : IO Unit :=
  reject name (parse patch)

def main : IO Unit := do
  let headers := "--- a/file\n+++ b/file\n"
  let replacement := headers ++ "@@ -1 +1 @@ title\n-old\n+new\n"
  let patch ← unwrap (parse replacement)
  check "render golden" (render patch) replacement
  check "exact application" (← unwrap (apply patch "old\n")) "new\n"
  reject "no relocation" (apply patch "other\nold\n")
  reject "wrong final LF" (apply patch "old")
  let context ← unwrap (parse (headers ++ "@@ -1,2 +1,2 @@\n first\n-x\n+y\n"))
  reject "strict context" (apply context "wrong\nx\n")
  let wrongNew ← unwrap (parse (headers ++ "@@ -1 +2 @@\n-x\n+y\n"))
  reject "strict target coordinate" (apply wrongNew "x\n")
  let overlap ← unwrap (parse (headers ++ "@@ -1 +1 @@\n-x\n+y\n@@ -1 +1 @@\n-x\n+z\n"))
  reject "overlapping hunks" (apply overlap "x\n")
  let insertion ← unwrap (parse (headers ++ "@@ -1,0 +2 @@\n+middle\n"))
  check "empty range after first line"
    (← unwrap (apply insertion "first\nlast\n")) "first\nmiddle\nlast\n"
  reject "cannot insert after an unterminated line" (apply insertion "first")
  let marker := "\\ No newline at end of file\n"
  let withoutLF := headers ++ "@@ -1 +1 @@\n-é\n" ++ marker ++ "+文\n" ++ marker
  let patch ← unwrap (parse withoutLF)
  check "render both no-newline markers" (render patch) withoutLF
  check "apply preserves no-newline markers" (← unwrap (apply patch "é")) "文"
  reject "wrong source LF before a suffix" (apply patch "é\nsuffix\n")
  let noFinalLF ← unwrap (parse (headers ++ "@@ -1 +1 @@\n-x\n+y\n" ++ marker))
  reject "unterminated output cannot precede unchanged suffix" (apply noFinalLF "x\nsuffix\n")
  malformed "truncated body" (headers ++ "@@ -1 +1 @@\n-x\n")
  malformed "extra body" (replacement ++ "+y\n")
  malformed "nonempty zero start" (headers ++ "@@ -0 +1 @@\n-x\n+y\n")
  malformed "missing hunk" headers
  malformed "binary patch" "diff --git a/file b/file\nGIT binary patch\n"
  malformed "rename" "diff --git a/file b/moved\nsimilarity index 100%\nrename from file\nrename to moved\n"
  malformed "multiple files" (replacement ++ replacement)
  malformed "missing final patch LF" (replacement.dropEnd 1).toString
  malformed "orphan marker" (replacement ++ marker ++ marker)
  malformed "old-side line after marker"
    (headers ++ "@@ -1,2 +1 @@\n-x\n" ++ marker ++ "-y\n+z\n")
  let examples := #["", "\n", "é", "é\n", "a\nb\n", "x\r\ny\r\n", "x\n\ny", "--- x\n+++ y\n"]
  for source in examples do
    for target in examples do
      let generated := diff source target
      let reparsed ← unwrap (parse (render generated))
      check "parse/render round trip" reparsed generated
      check "diff/apply round trip" (← unwrap (apply reparsed source)) target
  let farApart := "same\n1\n2\n3\n4\n5\n6\n7\nsame\n"
  let target := "first\n1\n2\n3\n4\n5\n6\n7\nlast\n"
  let .file _ hunks := diff farApart target
    | throw (IO.userError "expected a multi-hunk patch")
  check "separated changes generate multiple hunks" hunks.size 2
  check "multi-hunk application" (← unwrap (apply (diff farApart target) farApart)) target
  check "zero-context application" (← unwrap (apply (diff farApart target (context := 0)) farApart))
    target
  IO.println "Leansplice golden and round-trip tests passed."
