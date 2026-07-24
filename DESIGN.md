# Design

## Motivation

The upstream [hackage2nix](https://github.com/NixOS/cabal2nix) tool
generates a single 366k-line `hackage-packages.nix` file targeting
nixpkgs. This creates two problems for the ekapkgs ecosystem:

1. **Wrong dependency names.** hackage2nix resolves system library
   dependencies against nixpkgs attribute paths. nixpkgs has deprecated
   aliases (e.g. `libxinerama` at the top level) that don't exist in
   corepkgs, where the canonical path is `xorg.libXinerama`. This
   forced us to maintain a large aliases overlay mapping ~200 names.

2. **Monolithic output.** A single 366k-line file makes git diffs
   unreadable, defeats incremental evaluation, and forces a full
   regeneration for any change.

hackage2ekapkgs solves both by resolving deps against the actual
target package set and writing one file per package.

## Architecture

The tool inherits the upstream cabal2nix pipeline and modifies the
dependency resolution target and output stage.

### Pipeline

```
all-cabal-hashes  ──┐
                    ├──▶  resolve deps  ──▶  render Nix  ──▶  write per-pkg files
config YAML files ──┘     against            expressions      + index
                          --pkgs-path
```

1. **Read Hackage.** Walk the extracted all-cabal-hashes directory tree
   to discover every `<name>/<version>/<name>.cabal` + `.json` pair.

2. **Read configuration.** Merge compiler config (GHC boot libs),
   Stackage version pins, broken package lists, and maintainer
   assignments from YAML files passed via `--config`.

3. **Resolve system dependencies.** Evaluate `derivation-attr-paths.nix`
   against the package set at `--pkgs-path` using `nix-instantiate`.
   This builds a map from attribute names to full paths, used to
   resolve Cabal `extra-libraries` and `pkgconfig-depends` entries.

4. **Process packages in parallel.** For each package, parse the
   `.cabal` file, apply flag heuristics, resolve Haskell and system
   dependencies, and render a `callPackage` Nix expression.

5. **Write output.** Each package gets `<output-dir>/<name>/default.nix`.
   An index at `<output-dir>/default.nix` composes all packages.

### Upstream packages consolidated

The upstream cabal2nix repository is a monorepo with four Haskell
packages. We flattened them into one:

| Upstream package | Role | Disposition |
|---|---|---|
| `cabal2nix` (library) | Cabal-to-Nix conversion core | Inlined into `src/` |
| `cabal2nix` (executable) | Single-package converter CLI | Removed |
| `hackage2nix` (executable) | Bulk Hackage converter | Kept as `hackage2ekapkgs` |
| `distribution-nixpkgs` | Nix metadata types, PackageMap, attr-path evaluator | Inlined into `src/` |
| `language-nix` | Nix AST types and pretty-printing | Inlined into `src/` |
| `hackage-db` | Hackage tarball parsing | Kept as external dependency |

The library code is unchanged from upstream. Only the executable
(`hackage2ekapkgs/Main.hs`), the attribute path evaluator
(`derivation-attr-paths.nix`), the package map reader
(`src/Distribution/Nixpkgs/PackageMap.hs`), and the system dependency
name mapping (`src/Distribution/Nixpkgs/Haskell/FromCabal/Name.hs`)
are modified.

## Key decisions

### Per-package output over monolith

Each package gets its own directory and `default.nix`:

```
hackage/
  aeson/default.nix
  lens/default.nix
  ...
  default.nix          # index that composes all packages
```

Each per-package file is a self-contained overlay:

```nix
{ pkgs, lib, callPackage }:
self: {
  aeson = callPackage ({ mkDerivation, ... }: mkDerivation { ... }) { ... };
}
```

The index composes them with `foldl'`. This means:

- Git diffs are scoped to the packages that changed.
- Nix can cache evaluation per-file.
- Individual packages can be regenerated without touching the rest
  (not yet implemented, but the format supports it).

### Resolve against the target package set

The `--pkgs-path` flag points to the package set that will actually
consume the generated expressions (corepkgs). The
`derivation-attr-paths.nix` evaluator walks this set to discover all
derivation attribute paths, so generated `inherit (pkgs) foo`
references use names that actually exist.

This eliminates the aliases overlay that was previously needed to
bridge nixpkgs names to corepkgs names.

### libNixName adaptations

The `libNixName` function maps Cabal library names (like `"bz2"`,
`"ssl"`, `"Xinerama"`) to Nix package attribute names. We updated
several mappings for corepkgs:

| Cabal name | nixpkgs mapping | ekapkgs mapping | Reason |
|---|---|---|---|
| `"lapack"` | `liblapack` | `lapack` | corepkgs uses `lapack` directly |
| `"openblas"` | `openblasCompat` | `openblas` | no compat alias needed |
| `"libxxhash"` | `xxhash` | `xxHash` | corepkgs preserves upstream casing |
| `"idn"` | `libidn` | `libidn2` | corepkgs only has v2 |
| `"uuid"` | `libossp_uuid` | `libossp-uuid` | corepkgs uses hyphens |

Additional mappings will be needed as the corepkgs package set grows.

### Config files as absolute paths

Upstream hackage2nix reads config files relative to the `--nixpkgs`
directory. Since we decouple from nixpkgs, config file paths are now
absolute (or relative to cwd). This makes it straightforward to keep
configuration in the downstream `haskell-packages` repository.

### PostProcess hook cleanup

Upstream PostProcess.hs contains per-package fixup hooks. Two categories
of hooks reference nixpkgs-specific nested scopes that don't exist in
corepkgs:

- `pkgs.qt5.qtbase` (qtah-cpp-qt5, qtah-qt5)
- `pkgs.gst_all_1.*` (gi-gst, gi-gstaudio, gi-gstbase, gi-gstvideo)

These hooks were removed. All other hooks use flat `pkgs.*` references
(which are resolved by `derivation-attr-paths.nix` against the target
package set) or `self.*` references (Haskell-to-Haskell deps), and
work unchanged.

Hooks that use `lib.getDev`/`lib.getLib` (freenect, HFuse, libxml,
gi-cairo) are retained — corepkgs inherits these functions from
nix-lib.

## Future work

- Incremental regeneration: only regenerate packages whose Cabal files
  changed since the last run.
