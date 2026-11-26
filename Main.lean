import Leansplice

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["apply", patchPath, sourcePath] =>
      let patchText ← IO.FS.readFile patchPath
      let source ← IO.FS.readFile sourcePath
      match (Leansplice.parse patchText).bind (Leansplice.apply · source) with
      | .ok output =>
        IO.print output
        return 0
      | .error error =>
        IO.eprintln s!"leansplice: {error}"
        return 1
    | ["diff", oldPath, newPath] =>
      let source ← IO.FS.readFile oldPath
      let target ← IO.FS.readFile newPath
      IO.print (Leansplice.render (Leansplice.diff source target))
      return 0
    | _ =>
      IO.eprintln "Usage: leansplice apply PATCH FILE | leansplice diff OLD NEW"
      return 2
  catch error =>
    IO.eprintln s!"leansplice: {error}"
    return 1
