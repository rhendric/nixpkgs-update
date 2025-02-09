{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Check
  ( result,
    -- exposed for testing:
    hasVersion
  )
where

import Control.Applicative (many)
import Data.Char (isDigit, isLetter)
import Data.Maybe (fromJust)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Language.Haskell.TH.Env (envQ)
import OurPrelude
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Exit
import System.IO.Temp (withSystemTempDirectory)
import Text.Regex.Applicative.Text (RE', (=~))
import qualified Text.Regex.Applicative.Text as RE
import Utils (UpdateEnv (..), Version, nixBuildOptions)

default (T.Text)

treeBin :: String
treeBin = fromJust ($$(envQ "TREE") :: Maybe String) <> "/bin/tree"

procTree :: [String] -> ProcessConfig () () ()
procTree = proc treeBin

gistBin :: String
gistBin = fromJust ($$(envQ "GIST") :: Maybe String) <> "/bin/gist"

procGist :: [String] -> ProcessConfig () () ()
procGist = proc gistBin

timeoutBin :: String
timeoutBin = fromJust ($$(envQ "TIMEOUT") :: Maybe String) <> "/bin/timeout"

data BinaryCheck = BinaryCheck
  { filePath :: FilePath,
    zeroExitCode :: Bool,
    versionPresent :: Bool
  }

isWordCharacter :: Char -> Bool
isWordCharacter c = (isDigit c) || (isLetter c)

isNonWordCharacter :: Char -> Bool
isNonWordCharacter c = not (isWordCharacter c)

-- | Construct regex: /.*\b${version}\b.*/s
versionRegex :: Text -> RE' ()
versionRegex version =
  (\_ -> ()) <$> (
    (((many RE.anySym) <* (RE.psym isNonWordCharacter)) <|> (RE.pure ""))
    *> (RE.string version) <*
    ((RE.pure "") <|> ((RE.psym isNonWordCharacter) *> (many RE.anySym)))
  )

hasVersion :: Text -> Text -> Bool
hasVersion contents expectedVersion =
  isJust $ contents =~ versionRegex expectedVersion

checkTestsBuild :: Text -> IO Bool
checkTestsBuild attrPath = do
  let timeout = "10m"
  let
    args =
        [ T.unpack timeout, "nix-build" ] ++
        nixBuildOptions
          ++ [ "-E",
               "{ config }: (import ./. { inherit config; })."
                 ++ (T.unpack attrPath)
                 ++ ".tests or {}"
             ]
  r <- runExceptT $ ourReadProcessInterleaved $ proc "timeout" args
  case r of
    Left errorMessage -> do
      T.putStrLn $ attrPath <> ".tests process failed with output: " <> errorMessage
      return False
    Right (exitCode, output) -> do
      case exitCode of
        ExitFailure 124 -> do
          T.putStrLn $ attrPath <> ".tests took longer than " <> timeout <> " and timed out. Other output: " <> output
          return False
        ExitSuccess -> return True
        _ -> return False

-- | Run a program with provided argument and report whether the output
-- mentions the expected version
checkBinary :: Text -> Version -> FilePath -> IO BinaryCheck
checkBinary argument expectedVersion program = do
  eResult <-
    runExceptT $
      withSystemTempDirectory
        "nixpkgs-update"
        ( ourLockedDownReadProcessInterleaved $
            shell ("systemd-run --user --wait --property=RuntimeMaxSec=2 " <> program <> " " <> T.unpack argument)
        )
  case eResult of
    Left (_ :: Text) -> return $ BinaryCheck program False False
    Right (exitCode, contents) ->
      return $ BinaryCheck program (exitCode == ExitSuccess) (hasVersion contents expectedVersion)

checks :: [Version -> FilePath -> IO BinaryCheck]
checks =
  [ checkBinary "",
    checkBinary "-V",
    checkBinary "-v",
    checkBinary "--version",
    checkBinary "version",
    checkBinary "-h",
    checkBinary "--help",
    checkBinary "help"
  ]

someChecks :: BinaryCheck -> [IO BinaryCheck] -> IO BinaryCheck
someChecks best [] = return best
someChecks best (c : rest) = do
  current <- c
  let nb = newBest current
  case nb of
    BinaryCheck _ True True -> return nb
    _ -> someChecks nb rest
  where
    newBest :: BinaryCheck -> BinaryCheck
    newBest (BinaryCheck _ currentExit currentVersionPresent) =
      BinaryCheck
        (filePath best)
        (zeroExitCode best || currentExit)
        (versionPresent best || currentVersionPresent)

-- | Run a program with various version or help flags and report
-- when they succeded
runChecks :: Version -> FilePath -> IO BinaryCheck
runChecks expectedVersion program =
  someChecks (BinaryCheck program False False) checks'
  where
    checks' = map (\c -> c expectedVersion program) checks

checkTestsBuildReport :: Bool -> Text
checkTestsBuildReport False =
  "- Warning: a test defined in `passthru.tests` did not pass"
checkTestsBuildReport True =
  "- The tests defined in `passthru.tests`, if any, passed"

checkReport :: BinaryCheck -> Text
checkReport (BinaryCheck p False False) =
  "- Warning: no invocation of "
    <> T.pack p
    <> " had a zero exit code or showed the expected version"
checkReport (BinaryCheck p _ _) =
  "- " <> T.pack p <> " passed the binary check."

ourLockedDownReadProcessInterleaved ::
  MonadIO m =>
  ProcessConfig stdin stdoutIgnored stderrIgnored ->
  FilePath ->
  ExceptT Text m (ExitCode, Text)
ourLockedDownReadProcessInterleaved processConfig tempDir =
  processConfig & setWorkingDir tempDir
    & setEnv [("EDITOR", "echo"), ("HOME", "/we-dont-write-to-home")]
    & ourReadProcessInterleaved

foundVersionInOutputs :: Text -> String -> IO (Maybe Text)
foundVersionInOutputs expectedVersion resultPath =
  hush
    <$> runExceptT
      ( do
          (exitCode, _) <-
            proc "grep" ["-r", T.unpack expectedVersion, resultPath]
              & ourReadProcessInterleaved
          case exitCode of
            ExitSuccess ->
              return $
                "- found "
                  <> expectedVersion
                  <> " with grep in "
                  <> T.pack resultPath
                  <> "\n"
            _ -> throwE "grep did not find version in file names"
      )

foundVersionInFileNames :: Text -> String -> IO (Maybe Text)
foundVersionInFileNames expectedVersion resultPath =
  hush
    <$> runExceptT
      ( do
          (_, contents) <-
            shell ("find " <> resultPath) & ourReadProcessInterleaved
          (contents =~ versionRegex expectedVersion) & hoistMaybe
            & noteT (T.pack "Expected version not found")
          return $
            "- found "
              <> expectedVersion
              <> " in filename of file in "
              <> T.pack resultPath
              <> "\n"
      )

treeGist :: String -> IO (Maybe Text)
treeGist resultPath =
  hush
    <$> runExceptT
      ( do
          contents <- procTree [resultPath] & ourReadProcessInterleavedBS_
          g <-
            shell gistBin & setStdin (byteStringInput contents)
              & ourReadProcessInterleaved_
          return $ "- directory tree listing: " <> g <> "\n"
      )

duGist :: String -> IO (Maybe Text)
duGist resultPath =
  hush
    <$> runExceptT
      ( do
          contents <- proc "du" [resultPath] & ourReadProcessInterleavedBS_
          g <-
            shell gistBin & setStdin (byteStringInput contents)
              & ourReadProcessInterleaved_
          return $ "- du listing: " <> g <> "\n"
      )

result :: MonadIO m => UpdateEnv -> String -> m Text
result updateEnv resultPath =
  liftIO $ do
    let expectedVersion = newVersion updateEnv
        binaryDir = resultPath <> "/bin"
    testsBuild <- checkTestsBuild (packageName updateEnv)
    binExists <- doesDirectoryExist binaryDir
    binaries <-
      if binExists
        then
          ( do
              fs <- listDirectory binaryDir
              filterM doesFileExist (map (\f -> binaryDir ++ "/" ++ f) fs)
          )
        else return []
    checks' <- forM binaries $ \binary -> runChecks expectedVersion binary
    let passedZeroExitCode =
          (T.pack . show)
            ( foldl
                ( \acc c ->
                    if zeroExitCode c
                      then acc + 1
                      else acc
                )
                0
                checks' ::
                Int
            )
        passedVersionPresent =
          (T.pack . show)
            ( foldl
                ( \acc c ->
                    if versionPresent c
                      then acc + 1
                      else acc
                )
                0
                checks' ::
                Int
            )
        numBinaries = (T.pack . show) (length binaries)
    someReports <-
      fromMaybe ""
        <$> foundVersionInOutputs expectedVersion resultPath
        <> foundVersionInFileNames expectedVersion resultPath
        <> treeGist resultPath
        <> duGist resultPath
    return $
      let testsBuildSummary = checkTestsBuildReport testsBuild
          c = T.intercalate "\n" (map checkReport checks')
          binaryCheckSummary =
            "- "
              <> passedZeroExitCode
              <> " of "
              <> numBinaries
              <> " passed binary check by having a zero exit code."
          versionPresentSummary =
            "- "
              <> passedVersionPresent
              <> " of "
              <> numBinaries
              <> " passed binary check by having the new version present in output."
       in [interpolate|
              $testsBuildSummary
              $c
              $binaryCheckSummary
              $versionPresentSummary
              $someReports
            |]
