import Lean.Util.Diff

namespace Leansplice

/-- A line in a text file, excluding its LF delimiter. -/
structure TextLine where
  text : String
  terminated : Bool := true
  deriving Repr, BEq, Hashable, Inhabited

inductive EditKind where
  | context
  | remove
  | add
  deriving Repr, BEq, Inhabited

structure Edit where
  kind : EditKind
  line : TextLine
  deriving Repr, BEq, Inhabited

/-- Nonempty ranges are one-based; an empty range starts after that many lines. -/
structure LineRange where
  start : Nat
  count : Nat
  deriving Repr, BEq, Inhabited

structure Hunk where
  oldRange : LineRange
  newRange : LineRange
  sectionHeader : String := ""
  edits : Array Edit
  deriving Repr, BEq, Inhabited

structure FileHeader where
  oldFile : String
  newFile : String
  prelude : Array String := #[]
  deriving Repr, BEq, Inhabited

/-- A patch to one text file, or an empty patch (no change). -/
inductive Patch where
  | empty
  | file (header : FileHeader) (hunks : Array Hunk)
  deriving Repr, BEq, Inhabited

inductive Error where
  | parse (line : Nat) (message : String)
  | apply (hunk : Nat) (message : String)
  deriving Repr, BEq, Inhabited

instance : ToString Error where
  toString
    | .parse line message => s!"patch line {line}: {message}"
    | .apply hunk message => s!"hunk {hunk}: {message}"

private def EditKind.old (kind : EditKind) : Bool := kind != .add
private def EditKind.new (kind : EditKind) : Bool := kind != .remove

private def EditKind.prefix : EditKind → Char
  | .context => ' '
  | .remove => '-'
  | .add => '+'

private def LineRange.offset (range : LineRange) : Nat :=
  if range.count == 0 then range.start else range.start - 1

private def LineRange.atOffset (offset count : Nat) : LineRange :=
  ⟨if count == 0 then offset else offset + 1, count⟩

private def LineRange.render (range : LineRange) : String :=
  if range.count == 1 then toString range.start else s!"{range.start},{range.count}"

private def noNewline : String := "\\ No newline at end of file"

private def splitText (text : String) : Array TextLine := Id.run do
  let parts := (text.splitOn "\n").toArray
  let mut lines := #[]
  for i in [:parts.size - 1] do
    lines := lines.push ⟨parts[i]!, true⟩
  let last := parts.back!
  return if last.isEmpty then lines else lines.push ⟨last, false⟩

private def validateHunk (hunk : Hunk) : Except String Unit := do
  let mut oldCount := 0
  let mut newCount := 0
  let mut oldEnded := false
  let mut newEnded := false
  let mut changed := false
  for edit in hunk.edits do
    if edit.line.text.contains '\n' || (!edit.line.terminated && edit.line.text.isEmpty) then
      throw "invalid line content"
    if edit.kind.old then
      if oldEnded then throw "old-side line follows a no-newline marker"
      oldCount := oldCount + 1
      oldEnded := !edit.line.terminated
    if edit.kind.new then
      if newEnded then throw "new-side line follows a no-newline marker"
      newCount := newCount + 1
      newEnded := !edit.line.terminated
    changed := changed || edit.kind != .context
  if oldCount != hunk.oldRange.count || newCount != hunk.newRange.count then
    throw "hunk body does not match its line counts"
  if (oldCount > 0 && hunk.oldRange.start == 0) ||
     (newCount > 0 && hunk.newRange.start == 0) then
    throw "a nonempty range must start at line 1 or later"
  unless changed do throw "hunk contains no changes"

private def parseRange (sign : String) (token : String) : Option LineRange := do
  if !token.startsWith sign then none else
    match (token.drop 1).toString.splitOn "," with
    | [start] => return ⟨← start.toNat?, 1⟩
    | [start, count] => return ⟨← start.toNat?, ← count.toNat?⟩
    | _ => none

private def parseHunkHeader (text : String) : Option Hunk := do
  let oldToken :: newToken :: tail ← pure ((text.drop 3).toString.splitOn " ")
    | none
  let ending := String.intercalate " " tail
  let sectionHeader := (ending.drop 2).toString
  if !ending.startsWith "@@" || (!sectionHeader.isEmpty && !sectionHeader.startsWith " ") then
    none
  else
    return ⟨← parseRange "-" oldToken, ← parseRange "+" newToken, sectionHeader, #[]⟩

private def parseHunks (lines : Array TextLine) (start : Nat) : Except Error (Array Hunk) := do
  let mut hunks := #[]
  let mut i := start
  while i < lines.size do
    let headerLine := i + 1
    let raw := lines[i]!.text
    let some hunk := if raw.startsWith "@@ " then parseHunkHeader raw else none
      | throw (.parse headerLine "expected a unified hunk header")
    i := i + 1
    let mut edits := #[]
    let mut oldCount := 0
    let mut newCount := 0
    while i < lines.size && (oldCount < hunk.oldRange.count || newCount < hunk.newRange.count) do
      let raw := lines[i]!.text
      let kind : EditKind ← match raw.front? with
        | none | some ' ' => pure .context
        | some '-' => pure .remove
        | some '+' => pure .add
        | _ => throw (.parse (i + 1) "expected a context, removal, or addition line")
      oldCount := oldCount + (if kind.old then 1 else 0)
      newCount := newCount + (if kind.new then 1 else 0)
      if oldCount > hunk.oldRange.count || newCount > hunk.newRange.count then
        throw (.parse (i + 1) "hunk body exceeds its line counts")
      i := i + 1
      let marked := i < lines.size && lines[i]!.text == noNewline
      edits := edits.push ⟨kind, ⟨(raw.drop 1).toString, !marked⟩⟩
      if marked then i := i + 1
    let hunk := { hunk with edits }
    (validateHunk hunk).mapError (.parse headerLine)
    hunks := hunks.push hunk
  return hunks

/-- Parse an LF-delimited unified diff. File labels and Git's text prelude are opaque. -/
def parse (patch : String) : Except Error Patch := do
  if patch.isEmpty then return .empty
  let lines := splitText patch
  unless lines.back!.terminated do
    throw (.parse lines.size "patch must end with an LF")
  let lineAt (index : Nat) : String := (lines[index]?.map (·.text)).getD ""
  let mut i := 0
  let mut prelude := #[]
  if lines[0]!.text.startsWith "diff --git " then
    prelude := prelude.push lines[0]!.text
    i := i + 1
    if (lineAt i).startsWith "new file mode " || (lineAt i).startsWith "deleted file mode " then
      prelude := prelude.push (lineAt i)
      i := i + 1
    else if (lineAt i).startsWith "old mode " && (lineAt (i + 1)).startsWith "new mode " then
      i := i + 2
    if (lineAt i).startsWith "index " then
      prelude := prelude.push (lineAt i)
      i := i + 1
  let readLabel (index : Nat) (marker : String) : Except Error String := do
    let raw := lineAt index
    if !raw.startsWith marker || raw == marker then
      throw (.parse (index + 1) s!"expected a {marker.trimAscii.toString} file header")
    return (raw.drop 4).toString
  let oldFile ← readLabel i "--- "
  let newFile ← readLabel (i + 1) "+++ "
  let hunks ← parseHunks lines (i + 2)
  if hunks.isEmpty then throw (.parse (i + 3) "expected at least one hunk")
  return .file ⟨oldFile, newFile, prelude⟩ hunks

/-- Render a patch, using the short form for ranges of one line. -/
def render : Patch → String
  | .empty => ""
  | .file header hunks => Id.run do
    let mut out := ""
    for line in header.prelude do
      out := (out ++ line).push '\n'
    out := out ++ s!"--- {header.oldFile}\n+++ {header.newFile}\n"
    for hunk in hunks do
      out := out ++
        s!"@@ -{hunk.oldRange.render} +{hunk.newRange.render} @@{hunk.sectionHeader}\n"
      for edit in hunk.edits do
        out := ((out.push edit.kind.prefix) ++ edit.line.text).push '\n'
        if !edit.line.terminated then
          out := (out ++ noNewline).push '\n'
    return out

private def applyHunks (hunks : Array Hunk) (input : Array TextLine) :
    Except Error (Array TextLine) := do
  let mut cursor := 0
  let mut output : Array TextLine := #[]
  for h in [:hunks.size] do
    let fail := Error.apply (h + 1)
    let hunk := hunks[h]!
    (validateHunk hunk).mapError fail
    let oldOffset := hunk.oldRange.offset
    if oldOffset < cursor || oldOffset + hunk.oldRange.count > input.size then
      throw (fail "old range is out of bounds or overlaps an earlier hunk")
    let gap := oldOffset - cursor
    if hunk.newRange.offset != output.size + gap then
      throw (fail "new range does not match the output line number")
    for i in [cursor:oldOffset] do
      if (output.back?.map (! ·.terminated)).getD false then
        throw (fail "output has a line after an unterminated line")
      output := output.push input[i]!
    cursor := oldOffset
    for edit in hunk.edits do
      if edit.kind.old then
        if input[cursor]! != edit.line then
          throw (fail s!"source line {cursor + 1} does not match")
        cursor := cursor + 1
      if edit.kind.new then
        if (output.back?.map (! ·.terminated)).getD false then
          throw (fail "output has a line after an unterminated line")
        output := output.push edit.line
  if cursor < input.size && (output.back?.map (! ·.terminated)).getD false then
    throw (.apply hunks.size "output has a line after an unterminated line")
  return output ++ input.extract cursor input.size

/-- Apply at the stated coordinates, checking every old-side line and its LF. -/
def apply (patch : Patch) (source : String) : Except Error String := do
  let .file header hunks := patch | return source
  if hunks.isEmpty then throw (.apply 1 "expected at least one hunk")
  if header.oldFile == "/dev/null" && !source.isEmpty then
    throw (.apply 1 "a creation patch requires empty source text")
  let lines ← applyHunks hunks (splitText source)
  if header.newFile == "/dev/null" && !lines.isEmpty then
    throw (.apply hunks.size "a deletion patch must produce empty text")
  let mut output := ""
  for line in lines do
    output := output ++ line.text
    if line.terminated then output := output.push '\n'
  return output

private def diffWindows (edits : Array (Lean.Diff.Action × TextLine)) (context : Nat) :
    Array (Nat × Nat) := Id.run do
  let mut windows := #[]
  let mut current : Option (Nat × Nat) := none
  for i in [:edits.size] do
    if edits[i]!.1 != .skip then
      let start := i - context
      let stop := min (i + context + 1) edits.size
      if let some (previousStart, previousStop) := current then
        if start ≤ previousStop then
          current := some (previousStart, stop)
        else
          windows := windows.push (previousStart, previousStop)
          current := some (start, stop)
      else
        current := some (start, stop)
  return if let some window := current then windows.push window else windows

/-- Generate a unified patch with three context lines by default. Labels have no LF. -/
def diff (source target : String) (oldFile := "a/file") (newFile := "b/file")
    (context : Nat := 3) : Patch := Id.run do
  let edits := Lean.Diff.diff (splitText source) (splitText target)
  let windows := diffWindows edits context
  if windows.isEmpty then return .empty
  let mut oldOffset := 0
  let mut newOffset := 0
  let mut previousStop := 0
  let mut hunks := #[]
  for (start, stop) in windows do
    let gap := start - previousStop
    oldOffset := oldOffset + gap
    newOffset := newOffset + gap
    let mut body := #[]
    let mut oldCount := 0
    let mut newCount := 0
    for i in [start:stop] do
      let (action, line) := edits[i]!
      let kind := match action with
        | .delete => EditKind.remove
        | .insert => EditKind.add
        | .skip => EditKind.context
      body := body.push ⟨kind, line⟩
      if kind.old then oldCount := oldCount + 1
      if kind.new then newCount := newCount + 1
    hunks := hunks.push {
      oldRange := .atOffset oldOffset oldCount
      newRange := .atOffset newOffset newCount
      edits := body
    }
    oldOffset := oldOffset + oldCount
    newOffset := newOffset + newCount
    previousStop := stop
  return .file ⟨oldFile, newFile, #[]⟩ hunks

end Leansplice
