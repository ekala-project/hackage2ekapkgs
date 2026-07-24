# hackage2ekapkgs

Generate per-package Nix expressions from Hackage for the
[ekapkgs](https://github.com/ekala-project/corepkgs) package set.

Fork of [hackage2nix](https://github.com/NixOS/cabal2nix) from the
cabal2nix project, restructured to target corepkgs instead of nixpkgs
and to produce one Nix file per Hackage package rather than a single
monolithic file.

## Building

```
nix-build -I nixpkgs=<path-to-nixpkgs> -E '
  let nixpkgs = import <nixpkgs> {};
  in nixpkgs.haskellPackages.callCabal2nix "hackage2ekapkgs" ./. {}
'
```

## Usage

```
hackage2ekapkgs \
  --hackage /path/to/all-cabal-hashes \
  --preferred-versions <(cat /path/to/all-cabal-hashes/*/preferred-versions) \
  --pkgs-path /path/to/ekapkgs \
  --output-dir ./hackage \
  --config /path/to/compiler-config.yaml \
  --config /path/to/main.yaml \
  --config /path/to/stackage.yaml \
  --config /path/to/broken.yaml
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--hackage PATH` | Extracted all-cabal-hashes directory | `hackage` |
| `--preferred-versions PATH` | Hackage preferred-versions file | `hackage/preferred-versions` |
| `--pkgs-path PATH` | Package set for system dep resolution | `.` |
| `--output-dir PATH` | Where to write per-package Nix files | `hackage` |
| `--config PATH` | Configuration file (repeatable) | (required) |
| `--platform PLATFORM` | Target platform | `x86_64-linux` |

### Output

Each Hackage package gets its own file at `<output-dir>/<name>/default.nix`.
An index file at `<output-dir>/default.nix` composes them into a single
overlay.

## License

BSD-3-Clause (inherited from cabal2nix)
