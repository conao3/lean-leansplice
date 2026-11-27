# Development

- `Leansplice.lean` is the pure library: patch types, parsing, rendering, strict
  application, and generation. It must not read or write files.
- `Main.lean` is the CLI. Patch paths are labels, not destinations; the CLI
  takes its source path explicitly and writes only to stdout.
- `Tests.lean` covers the library; `scripts/git-differential.sh` checks both
  directions against Git.
- Use `nix develop --command make check` for the full check and `nix fmt` for
  the flake. `nix build` checks the distributable CLI.
