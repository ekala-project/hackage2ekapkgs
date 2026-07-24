-- | Build a lookup table from package identifiers to full attribute paths in the package set.
module Distribution.Nixpkgs.PackageMap
  ( PackageMap, readNixpkgPackageMap
  , resolve
  ) where

import Control.Lens
import qualified Data.Aeson as JSON
import qualified Data.ByteString.Lazy as LBS
import Data.Function
import Data.List (minimumBy)
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Set ( Set )
import qualified Data.Set as Set
import Language.Nix
import Paths_hackage2ekapkgs (getDataFileName)
import System.Process

type PackageMap = Map Identifier (Set Path)

-- | Evaluate a package set at a given (nix) path and build a 'Map'
--   keeping track of all 'Path's that end in a given 'Identifier'
--   and evaluate to a derivation.
--   This can be used to find an attribute 'Path' for an arbitrary
--   package name using 'resolve'.
--
--   Note: Evaluation of the package set is very expensive (takes multiple
--   seconds), so cache the result of this function if possible.
readNixpkgPackageMap :: String
                     -- ^ Path to package set, must be a valid nix path
                     -> Maybe String
                     -- ^ (Optional) argument attribute set to pass.
                     --   Must be a valid nix attribute set.
                     -> IO PackageMap
readNixpkgPackageMap pkgsPath pkgsArgs =
  identifierSet2PackageMap <$> readPkgSet pkgsPath pkgsArgs

readPkgSet :: String -> Maybe String -> IO (Set [String])
readPkgSet pkgsPath pkgsArgs = do
  pathsExpr <- getDataFileName "derivation-attr-paths.nix"
  let nixInstantiate = proc "nix-instantiate"
        [ "--strict"
        , "--json"
        , "--eval"
        , pathsExpr
        , "--arg", "pkgsPath", pkgsPath
        , "--arg", "pkgsArgs", fromMaybe "{}" pkgsArgs
        ]
  (_, Just h, _, _) <-
    createProcess nixInstantiate { std_out = CreatePipe, env = Nothing }
  buf <- LBS.hGetContents h
  either fail return $ JSON.eitherDecode buf

identifierSet2PackageMap :: Set [String] -> PackageMap
identifierSet2PackageMap = foldr insertIdentifier Map.empty
  where
    insertIdentifier :: [String] -> (PackageMap -> PackageMap)
    insertIdentifier rawPath =
      case parsePackage rawPath of
        Nothing -> id
        Just (i, p) -> Map.insertWith Set.union i $ Set.singleton p

parsePackage :: [String] -> Maybe (Identifier, Path)
parsePackage x
  | null x =
      error "Distribution.Nixpkgs.PackageMap.parsepackage: empty path is no valid identifier"
  | otherwise =
      if any needsQuoting x
        then Nothing
        else Just (ident # last x, path # map (review ident) x)

-- | Finds the shortest 'Path' in a 'PackageMap' that has the
--   given 'Identifier' as its last component.
resolve :: PackageMap -> Identifier -> Maybe Binding
resolve pkgMap i = case Map.lookup i pkgMap of
                      Nothing -> Nothing
                      Just ps -> let p = chooseShortestPath (Set.toList ps)
                                 in Just $ binding # (i,p)

chooseShortestPath :: [Path] -> Path
chooseShortestPath [] = error "chooseShortestPath: called with empty list argument"
chooseShortestPath ps = minimumBy (on compare (view (path . to length))) ps
