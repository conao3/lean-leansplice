import Std.Data.HashMap.Basic

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
    let label := ((raw.drop 4).takeWhile (· != '\t')).toString
    if !raw.startsWith marker || label.isEmpty then
      throw (.parse (index + 1) s!"expected a {marker.trimAscii.toString} file header")
    return label
  let oldFile ← readLabel i "--- "
  let newFile ← readLabel (i + 1) "+++ "
  let hunks ← parseHunks lines (i + 2)
  if hunks.isEmpty then throw (.parse (i + 3) "expected at least one hunk")
  return .file ⟨oldFile, newFile, prelude⟩ hunks

private def renderLabel (label : String) : String :=
  if label.contains ' ' then label.push '\t' else label

/-- Render a patch, using the short form for ranges of one line. -/
def render : Patch → String
  | .empty => ""
  | .file header hunks => Id.run do
    let mut out := ""
    for line in header.prelude do
      out := (out ++ line).push '\n'
    out := out ++ s!"--- {renderLabel header.oldFile}\n+++ {renderLabel header.newFile}\n"
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

private def diagonalY (x depth index : Nat) : Nat :=
  (Int.ofNat x + Int.ofNat depth - 2 * Int.ofNat index).toNat

private def previousDiagonal (last : Array Nat) (index : Nat) : Nat :=
  if index == 0 || (index < last.size && last[index - 1]! < last[index]!) then
    index
  else
    index - 1

private def traceMatches (frontiers : Array (Array Nat)) (endX endY : Nat) :
    Array (Nat × Nat) := Id.run do
  let mut pairs := #[]
  let mut x := endX
  let mut y := endY
  for i in [:frontiers.size] do
    let depth := frontiers.size - i
    let diagonal := ((Int.ofNat x - Int.ofNat y + Int.ofNat depth) / 2).toNat
    let previous := previousDiagonal frontiers[depth - 1]! diagonal
    let xBefore := frontiers[depth - 1]![previous]!
    let yBefore := diagonalY xBefore (depth - 1) previous
    while x > xBefore && y > yBefore do
      x := x - 1
      y := y - 1
      pairs := pairs.push (x, y)
    x := xBefore
    y := yBefore
  while x > 0 && y > 0 do
    x := x - 1
    y := y - 1
    pairs := pairs.push (x, y)
  return pairs.reverse

private def myersMatches (source target : Array TextLine) (limit : Nat) :
    Option (Array (Nat × Nat)) := Id.run do
  if source.size > target.size + limit || target.size > source.size + limit then
    return none
  let mut frontiers : Array (Array Nat) := #[]
  for depth in [:limit + 1] do
    let mut next : Array Nat := #[]
    for diagonal in [:depth + 1] do
      let mut x := 0
      if depth > 0 then
        let last := frontiers.back!
        let previous := previousDiagonal last diagonal
        x := last[previous]! + (if previous == diagonal then 0 else 1)
      let mut y := diagonalY x depth diagonal
      while x < source.size && y < target.size && source[x]! == target[y]! do
        x := x + 1
        y := y + 1
      if x == source.size && y == target.size then
        return some (traceMatches frontiers x y)
      next := next.push x
    frontiers := frontiers.push next
  return none

private structure Anchor where
  source : Nat
  target : Nat
  previous : Option Nat
  deriving Inhabited

private def anchorMatches (source target : Array TextLine) : Array (Nat × Nat) := Id.run do
  let mut positions : Std.HashMap TextLine (List Nat) := {}
  for i in [:target.size] do
    let j := target.size - i - 1
    positions := positions.alter target[j]! fun rest => some (j :: rest.getD [])
  let mut anchors : Array Anchor := #[]
  let mut tails : Array Nat := #[]
  for i in [:source.size] do
    let line := source[i]!
    if let j :: rest := positions.getD line [] then
      positions := positions.insert line rest
      let mut low := 0
      let mut high := tails.size
      if tails.back?.any (fun k => anchors[k]!.target < j) then
        low := high
      while low < high do
        let mid := (low + high) / 2
        if anchors[tails[mid]!]!.target < j then
          low := mid + 1
        else
          high := mid
      let previous := if low == 0 then none else some tails[low - 1]!
      let index := anchors.size
      anchors := anchors.push ⟨i, j, previous⟩
      tails := if low == tails.size then tails.push index else tails.set! low index
  let mut next := tails.back?
  let mut pairs := #[]
  while let some i := next do
    let anchor := anchors[i]!
    pairs := pairs.push (anchor.source, anchor.target)
    next := anchor.previous
  return pairs.reverse

private def editScript (source target : Array TextLine) : Array Edit := Id.run do
  let mut edits := #[]
  let mut prefixLength := 0
  while prefixLength < min source.size target.size &&
      source[prefixLength]! == target[prefixLength]! do
    edits := edits.push ⟨.context, source[prefixLength]!⟩
    prefixLength := prefixLength + 1
  let mut oldStop := source.size
  let mut newStop := target.size
  while oldStop > prefixLength && newStop > prefixLength &&
      source[oldStop - 1]! == target[newStop - 1]! do
    oldStop := oldStop - 1
    newStop := newStop - 1
  let oldMiddle := source.extract prefixLength oldStop
  let newMiddle := target.extract prefixLength newStop
  let pairs :=
    if oldMiddle.isEmpty || newMiddle.isEmpty then #[]
    else
      match myersMatches oldMiddle newMiddle 64 with
      | some pairs => pairs
      | none => anchorMatches oldMiddle newMiddle
  let mut oldCursor := prefixLength
  let mut newCursor := prefixLength
  for (oldIndex, newIndex) in pairs.push (oldMiddle.size, newMiddle.size) do
    let i := oldIndex + prefixLength
    let j := newIndex + prefixLength
    for k in [oldCursor:i] do
      edits := edits.push ⟨.remove, source[k]!⟩
    for k in [newCursor:j] do
      edits := edits.push ⟨.add, target[k]!⟩
    if i < oldStop then
      edits := edits.push ⟨.context, source[i]!⟩
      oldCursor := i + 1
      newCursor := j + 1
  for i in [oldStop:source.size] do
    edits := edits.push ⟨.context, source[i]!⟩
  return edits

private def diffWindows (edits : Array Edit) (context : Nat) :
    Array (Nat × Nat) := Id.run do
  let mut windows := #[]
  let mut current : Option (Nat × Nat) := none
  for i in [:edits.size] do
    if edits[i]!.kind != .context then
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

/-- Generate a unified patch with three context lines by default. Labels have no LF or tab. -/
def diff (source target : String) (oldFile := "a/file") (newFile := "b/file")
    (context : Nat := 3) : Patch := Id.run do
  let edits := editScript (splitText source) (splitText target)
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
      let edit := edits[i]!
      body := body.push edit
      if edit.kind.old then oldCount := oldCount + 1
      if edit.kind.new then newCount := newCount + 1
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
