{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main ( main ) where

import HackageGit

import Control.Lens
import Control.Monad
import Control.Monad.Par.Combinator
import Control.Monad.Par.IO
import Control.Monad.Trans ( liftIO )
import Data.List ( intercalate )
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Set ( Set )
import qualified Data.Set as Set
import Distribution.Nixpkgs.Fetch
import Distribution.Nixpkgs.Haskell as Derivation
import Distribution.Nixpkgs.Haskell.Constraint
import Distribution.Nixpkgs.Haskell.FromCabal
import Distribution.Nixpkgs.Haskell.FromCabal.Configuration as Config
import Distribution.Nixpkgs.Haskell.FromCabal.Flags
import Distribution.Nixpkgs.Haskell.FromCabal.Name (toNixName)
import Distribution.Nixpkgs.Haskell.Platform ( parsePlatformFromSystemLenient )
import Distribution.Nixpkgs.Haskell.OrphanInstances ( )
import Distribution.Nixpkgs.Meta
import Distribution.Nixpkgs.PackageMap
import Distribution.Package
import Distribution.PackageDescription hiding ( options, extraLibs, buildTools, homepage )
import Distribution.System
import Distribution.Types.PackageVersionConstraint
import Distribution.Text
import Distribution.Version
import Language.Nix
import Options.Applicative
import qualified Paths_hackage2ekapkgs as Main
import System.Directory ( createDirectoryIfMissing )
import System.FilePath
import System.IO
import Text.PrettyPrint.HughesPJClass hiding ( (<>) )
import Data.List.NonEmpty (NonEmpty)
import Data.Semigroup (sconcat)
import Options.Applicative.NonEmpty (some1)
import GHC.IO.Encoding (setLocaleEncoding)

type PackageSet = Map PackageName Version
type PackageMultiSet = Map PackageName (Set Version)

data CLI = CLI
  { hackageRepository :: FilePath
  , preferredVersionsFile :: Maybe FilePath
  , pkgsPath :: FilePath
  , pkgsArgs :: Maybe String
  , outputDir :: FilePath
  , configFiles :: NonEmpty FilePath
  , targetPlatform :: Platform
  }
  deriving (Show)

main :: IO ()
main = do
  setLocaleEncoding utf8
  let cliOptions :: Parser CLI
      cliOptions = CLI
        <$> strOption (long "hackage" <> help "path to Hackage git repository" <> value "hackage" <> showDefaultWith id <> metavar "PATH")
        <*> optional (strOption (long "preferred-versions" <> help "path to Hackage preferred-versions file" <> value "hackage/preferred-versions" <> showDefault <> metavar "PATH"))
        <*> strOption (long "pkgs-path" <> help "path to package set for system dependency resolution" <> value "." <> showDefaultWith id <> metavar "PATH")
        <*> optional (strOption (long "pkgs-args" <> help "Nix attribute set passed when importing --pkgs-path, e.g. '{ config.aliases.nixpkgs = false; }'" <> metavar "EXPR"))
        <*> strOption (long "output-dir" <> help "output directory for generated per-package .nix files" <> value "hackage" <> showDefaultWith id <> metavar "PATH")
        <*> some1 (strOption (long "config" <> help "path to configuration file" <> metavar "PATH"))
        <*> option (maybeReader parsePlatformFromSystemLenient) (long "platform" <> help "target platform to generate package set for" <> value (Platform X86_64 Linux) <> showDefaultWith display <> metavar "PLATFORM")

      pinfo :: ParserInfo CLI
      pinfo = info
              (   helper
              <*> infoOption ("hackage2ekapkgs " ++ prettyShow Main.version) (long "version" <> help "Show version number")
              <*> cliOptions
              )
              (  fullDesc
              <> header "hackage2ekapkgs generates per-package Nix expressions from Hackage for ekapkgs."
              )
  CLI {..} <- execParser pinfo

  config <- sconcat <$> mapM readConfiguration configFiles
  pkgMap <- readNixpkgPackageMap pkgsPath pkgsArgs
  preferredVersions <- readPreferredVersions (fromMaybe (hackageRepository </> "preferred-versions") preferredVersionsFile)
  let fixup = Map.delete "acme-everything"
              . over (at "hermes") (fmap (set (contains "1.3.4.3") False))
  hackage <- fixup <$> readHackage hackageRepository
  let
      corePackageSet :: PackageSet
      corePackageSet = Map.fromList [ (name, v) | PackageIdentifier name v <- Set.toList (Config.corePackages config) ]

      latestVersionSet :: PackageSet
      latestVersionSet = Map.map Set.findMax (Map.filter (not . Set.null) (Map.mapWithKey (enforcePreferredVersions preferredVersions) hackage))

      defaultPackageOverridesSet :: PackageSet
      defaultPackageOverridesSet = Map.fromList [ (name, resolveConstraint c hackage) | c@(PackageVersionConstraint name _) <- defaultPackageOverrides config ]

      generatedDefaultPackageSet :: PackageSet
      generatedDefaultPackageSet = (defaultPackageOverridesSet `Map.union` latestVersionSet) `Map.difference` corePackageSet

      latestCorePackageSet :: PackageSet
      latestCorePackageSet = latestVersionSet `Map.intersection` corePackageSet

      latestOverridePackageSet :: PackageSet
      latestOverridePackageSet = latestVersionSet `Map.intersection` defaultPackageOverridesSet

      extraPackageSet :: PackageMultiSet
      extraPackageSet = Map.unionsWith Set.union
                          [ Map.singleton name (Set.singleton (resolveConstraint c hackage)) | c@(PackageVersionConstraint name _) <- extraPackages config ]

      db :: PackageMultiSet
      db = Map.unionsWith Set.union [ Map.map Set.singleton generatedDefaultPackageSet
                                    , Map.map Set.singleton latestCorePackageSet
                                    , Map.map Set.singleton latestOverridePackageSet
                                    , extraPackageSet
                                    ]

      haskellResolver :: HaskellResolver
      haskellResolver (PackageVersionConstraint name vrange)
        | Just v <- Map.lookup name corePackageSet                = v `withinRange` vrange
        | Just v <- Map.lookup name generatedDefaultPackageSet    = v `withinRange` vrange
        | otherwise                                               = False

      -- Whether @pkgs.<i>@ is a derivation in the target package set.
      isTopLevelPackage :: Identifier -> Bool
      isTopLevelPackage i = maybe False (Set.member (path # [i])) (Map.lookup i pkgMap)

      nixpkgsResolver :: Identifier -> Maybe Binding
      nixpkgsResolver = resolve (Map.map (Set.map (over path ("pkgs":))) pkgMap)

      globalPackageMaintainers :: Map PackageName (Set Identifier)
      globalPackageMaintainers = Map.unionsWith Set.union [ Map.singleton p (Set.singleton m) | (m,ps) <- Map.toList (packageMaintainers config), p <- Set.toList ps ]

  -- Generate per-package definitions in parallel
  pkgEntries <- runParIO $ flip parMapM (Map.toAscList db) $ \(name, vs) -> do
    defs <- forM (Set.toAscList vs) $ \v -> liftIO $ do
      let pkgId :: PackageIdentifier
          pkgId = PackageIdentifier name v

      (descr, cabalSHA256) <- readPackage hackageRepository pkgId
      meta <- readPackageMeta hackageRepository pkgId

      let isInDefaultPackageSet, isHydraEnabled, isBroken :: Bool
          isInDefaultPackageSet = (== Just v) (Map.lookup name generatedDefaultPackageSet)
          isHydraEnabled = isInDefaultPackageSet && not (isBroken || name `Set.member` dontDistributePackages config)
          isBroken = any (withinRange v) [ vr | PackageVersionConstraint pn vr <- brokenPackages config, pn == name ]

          tarballSHA256 :: SHA256Hash
          tarballSHA256 = fromMaybe (error (display pkgId ++ ": meta data has no hash for the tarball"))
                                    (view (hashes . at "SHA256") meta)

          flagAssignment :: FlagAssignment
          flagAssignment = configureCabalFlags pkgId

          attr :: Identifier
          attr = if isInDefaultPackageSet then toNixName name else mangle pkgId

          drv :: Derivation
          drv = fromGenericPackageDescription haskellResolver nixpkgsResolver targetPlatform (compilerInfo config) flagAssignment [] descr
                  & src .~ urlDerivationSource ("mirror://hackage/" ++ display pkgId ++ ".tar.gz") tarballSHA256
                  & editedCabalFile .~ cabalSHA256
                  & metaSection.platforms %~ (Map.lookup name (supportedPlatforms config) <|>)
                  & metaSection.badPlatforms %~ (Map.lookup name (unsupportedPlatforms config) <|>)
                  & metaSection.hydraPlatforms %~ (if isHydraEnabled then id else const (Just Set.empty))
                  & metaSection.broken ||~ isBroken
                  & metaSection.maintainers .~ Map.findWithDefault Set.empty name globalPackageMaintainers
                  & metaSection.homepage .~ ""
                  & resolveSystemDependencies isTopLevelPackage (systemDependencyPaths config)

          overrides :: Doc
          overrides = fcat $ punctuate space [ renderOverride b <> semi | b <- Set.toList (view (dependencies . each) drv `Set.union` view extraFunctionArgs drv), not (isFromHackage b) ]

          -- Unresolved system dependencies are looked up lazily so that the
          -- package works once a downstream package set provides them.
          renderOverride :: Binding -> Doc
          renderOverride b
            | i `Set.member` view (metaSection . brokenIfMissing) drv
            = pPrint i <+> equals <+> (text "pkgs." <> pPrint i) <+> text "or null"
            | otherwise = pPrint b
            where i = view localName b

          body :: String
          body = render $ nest 2 $
            hang (pPrint attr <+> equals <+> text "callPackage") 2 (parens (pPrint drv)) <+> (braces overrides <> semi)

      return (attr, body)

    return (unPackageName name, defs)

  -- Write per-package files
  createDirectoryIfMissing True outputDir
  allAttrs <- fmap concat $ forM pkgEntries $ \(pkgName, defs) -> do
    let pkgDir = outputDir </> pkgName
        content = intercalate "\n\n" (map snd defs)
        fileContent = unlines
          [ "/* Generated by hackage2ekapkgs -- DO NOT EDIT */"
          , ""
          , "{ pkgs, lib, callPackage }:"
          , ""
          , "self: {"
          , ""
          , content
          , ""
          , "}"
          ]
    createDirectoryIfMissing True pkgDir
    writeFile (pkgDir </> "default.nix") fileContent
    return (map fst defs)

  -- Write the index that composes all per-package overlays
  let indexContent = unlines $
        [ "/* Generated by hackage2ekapkgs -- DO NOT EDIT */"
        , ""
        , "{ pkgs, lib, callPackage }:"
        , ""
        , "let"
        , "  compose = builtins.foldl'"
        , "    (acc: overlay: acc // overlay { inherit pkgs lib callPackage; } acc)"
        , "    {};"
        , ""
        , "  overlays = ["
        ] ++
        [ "    (import ./" ++ pkgName ++ ")"
        | (pkgName, _) <- pkgEntries
        ] ++
        [ "  ];"
        , ""
        , "in self: compose overlays"
        ]
  writeFile (outputDir </> "default.nix") indexContent

  hPutStrLn stderr $ "Generated " ++ show (length pkgEntries) ++ " package files in " ++ outputDir

-- | Apply explicit system dependency paths from the configuration, then
--   record every system, pkg-config or tool dependency that is still
--   unresolved in 'brokenIfMissing': bound to @null@ by the resolver, or
--   referenced as @pkgs.<name>@ by a PostProcess hook (which bypasses the
--   resolver) although the target package set has no such attribute.
resolveSystemDependencies :: (Identifier -> Bool) -> Map Identifier Path -> Derivation -> Derivation
resolveSystemDependencies isTopLevelPackage paths drv0 =
    drv & metaSection . brokenIfMissing .~ missing
  where
    -- Rename every non-Hackage binding of a name, so that a name bound to
    -- null in one dependency set (e.g. an unresolvable Haskell dependency)
    -- and to a system library in another still yields a single binding.
    drv = drv0 & over (dependencies . each) (Set.map rename)
               & over extraFunctionArgs (Set.map rename)

    rename :: Binding -> Binding
    rename b | isFromHackage b = b
    rename b = case Map.lookup (view localName b) paths of
      Just p | view path p == [nullIdent] -> binding # (view localName b, p)
             | otherwise -> binding # (view localName b, path # (ident # "pkgs" : view path p))
      Nothing -> b

    missing :: Set Identifier
    missing = Set.fromList $
      [ view localName b
      | l <- [pkgconfig, system, tool]
      , b <- Set.toList (foldMapOf (dependencies . l) id drv)
      , view (reference . path) b == [nullIdent]
      , not (view localName b `Map.member` paths)
      ] ++
      [ i
      | b <- Set.toList (foldMapOf (dependencies . each) id drv `Set.union` view extraFunctionArgs drv)
      , let i = view localName b
      , view (reference . path) b == [pkgsIdent, i]
      , not (i `Map.member` paths)
      , not (isTopLevelPackage i)
      ]

    pkgsIdent :: Identifier
    pkgsIdent = ident # "pkgs"

    nullIdent :: Identifier
    nullIdent = ident # "null"

isFromHackage :: Binding -> Bool
isFromHackage b = case view (reference . path) b of
                    ["self",_] -> True
                    _ -> False

readPreferredVersions :: FilePath -> IO [Constraint]
readPreferredVersions p = mapMaybe parsePreferredVersionsLine . lines <$> readFile p

parsePreferredVersionsLine :: String -> Maybe Constraint
parsePreferredVersionsLine [] = Nothing
parsePreferredVersionsLine ('-':'-':_) = Nothing
parsePreferredVersionsLine l = simpleParse l `mplus` error ("invalid preferred-versions line: " ++ show l)

enforcePreferredVersions :: [Constraint] -> PackageName -> Set Version -> Set Version
enforcePreferredVersions cs pkg = Set.filter (\v -> PackageIdentifier pkg v `satisfiesConstraints` cs)

resolveConstraint :: Constraint -> Hackage -> Version
resolveConstraint c = fromMaybe (error msg) . resolveConstraint' c
  where msg = unlines [ "constraint " ++ display c ++ " cannot be resolved in Hackage"
                      , "This could be due the package being missing in the hackage directory"
                      , "or the file system not being case sensitive."
                      ]

resolveConstraint' :: Constraint -> Hackage -> Maybe Version
resolveConstraint' (PackageVersionConstraint name vrange) hackage
  | Just vset' <- Map.lookup name hackage
  , vset <- Set.filter (`withinRange` vrange) vset'
  , not (Set.null vset)         = Just (Set.findMax vset)
  | otherwise                   = Nothing

mangle :: PackageIdentifier -> Identifier
mangle (PackageIdentifier name v) =
  toNixName name & ident %~ (++ '_' : [ if c == '.' then '_' else c | c <- display v ])
