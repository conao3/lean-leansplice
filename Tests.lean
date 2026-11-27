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

def repeatedRecords (label : String) (count : Nat) : String := Id.run do
  let mut text := ""
  for i in [:count] do
    text := text ++ s!"{label} {i}\n---\n"
  return text

def randomStep (seed : Nat) : Nat :=
  (1664525 * seed + 1013904223) % 4294967296

def randomText (seed size : Nat) : String × Nat := Id.run do
  let alphabet := #["alpha", "---", "", "é", "omega"]
  let mut seed := seed
  let mut text := ""
  for i in [:size] do
    seed := randomStep seed
    text := text ++ alphabet[(seed / 256) % alphabet.size]!
    if i + 1 < size || seed % 2 == 0 then text := text.push '\n'
  return (text, seed)

def main : IO Unit := do
  let headers := "--- a/file\n+++ b/file\n"
  let replacement := headers ++ "@@ -1 +1 @@ title\n-old\n+new\n"
  let patch ← unwrap (parse replacement)
  check "render golden" (render patch) replacement
  check "exact application" (← unwrap (apply patch "old\n")) "new\n"
  let gitHeader := "diff --git a/file b/file\n"
  let modes := "old mode 100644\nnew mode 100755\n"
  let index := "index 3367afd..3e75765\n"
  let modeChange ← unwrap (parse (gitHeader ++ modes ++ index ++ replacement))
  check "mode metadata does not block text application"
    (← unwrap (apply modeChange "old\n")) "new\n"
  check "render omits mode changes" (render modeChange) (gitHeader ++ index ++ replacement)
  malformed "mode-only patch" (gitHeader ++ modes)
  reject "no relocation" (apply patch "other\nold\n")
  reject "wrong final LF" (apply patch "old")
  let context ← unwrap (parse (headers ++ "@@ -1,2 +1,2 @@\n first\n-x\n+y\n"))
  reject "strict context" (apply context "wrong\nx\n")
  let blankContext ← unwrap (parse (headers ++ "@@ -1,3 +1,3 @@\n\n-x\n+y\n\n"))
  check "bare blank context counts on both sides"
    (← unwrap (apply blankContext "\nx\n\n")) "\ny\n\n"
  check "render restores the blank context prefix" (render blankContext)
    (headers ++ "@@ -1,3 +1,3 @@\n \n-x\n+y\n \n")
  reject "bare blank context is checked" (apply blankContext "unexpected\nx\n\n")
  let wrongNew ← unwrap (parse (headers ++ "@@ -1 +2 @@\n-x\n+y\n"))
  reject "strict target coordinate" (apply wrongNew "x\n")
  let overlap ← unwrap (parse (headers ++ "@@ -1 +1 @@\n-x\n+y\n@@ -1 +1 @@\n-x\n+z\n"))
  reject "overlapping hunks" (apply overlap "x\n")
  let insertion ← unwrap (parse (headers ++ "@@ -1,0 +2 @@\n+middle\n"))
  check "empty range after first line"
    (← unwrap (apply insertion "first\nlast\n")) "first\nmiddle\nlast\n"
  reject "cannot insert after an unterminated line" (apply insertion "first")
  let timestamp := "\t1970-01-01 00:00:00.000000000 +0000\n"
  let body := "@@ -1 +1 @@\n-x\n+y\n"
  let spaced ← unwrap (parse ("--- a/foo bar" ++ timestamp ++ "+++ b/foo bar" ++
    timestamp ++ body))
  check "render terminates spaced file labels with a tab" (render spaced)
    ("--- a/foo bar\t\n+++ b/foo bar\t\n" ++ body)
  check "spaced file labels round trip" (← unwrap (parse (render spaced))) spaced
  let creation := "@@ -0,0 +1 @@\n+created\n"
  let datedCreation ← unwrap (parse ("--- /dev/null" ++ timestamp ++ "+++ b/file" ++
    timestamp ++ creation))
  check "render strips header timestamps" (render datedCreation)
    ("--- /dev/null\n+++ b/file\n" ++ creation)
  check "creation with a timestamp" (← unwrap (apply datedCreation "")) "created\n"
  reject "timestamped creation requires empty source" (apply datedCreation "existing\n")
  let datedDeletion ← unwrap (parse ("--- a/file" ++ timestamp ++ "+++ /dev/null" ++
    timestamp ++ "@@ -1 +0,0 @@\n-x\n"))
  check "deletion with a timestamp" (← unwrap (apply datedDeletion "x\n")) ""
  reject "timestamped deletion must leave empty output" (apply datedDeletion "x\ny\n")
  malformed "timestamp without a file label" ("--- " ++ timestamp ++ "+++ b/file\n" ++ creation)
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
  let source := repeatedRecords "old" 2048
  let target := repeatedRecords "new" 2048
  let repeated ← unwrap (parse (render (diff source target)))
  check "repeated separator round trip" (← unwrap (apply repeated source)) target
  let .file _ repeatedHunks := repeated
    | throw (IO.userError "expected a repeated-record patch")
  let separatorCount := repeatedHunks.foldl (fun total hunk =>
    hunk.edits.foldl (fun count edit =>
      if edit.kind == .context && edit.line.text == "---" then count + 1 else count) total) 0
  check "repeated separators stay in context" separatorCount 2048
  let mut seed := 42
  for i in [:80] do
    let size := if i < 40 then 32 else 150
    let (source, next) := randomText seed (seed % size)
    let (target, next) := randomText next (next % size)
    seed := randomStep next
    let generated := diff source target (context := i % 5)
    let reparsed ← unwrap (parse (render generated))
    check s!"random round trip {i}" (← unwrap (apply reparsed source)) target
  IO.println "Leansplice golden and round-trip tests passed."
