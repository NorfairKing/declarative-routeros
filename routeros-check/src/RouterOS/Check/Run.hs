{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}

module RouterOS.Check.Run (routerosCheck) where

import Control.Monad (when)
import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import qualified Data.Text as T
import Path
import Path.IO
import RouterOS.Check
import RouterOS.Check.File
import RouterOS.Check.OptParse
import RouterOS.Check.Problem
import RouterOS.Check.Validation
import RouterOS.Check.Vocabulary
import System.Exit (die)
import System.IO (stderr)

-- | Only if the file has nothing wrong with it are the halves written, and
-- there is no way to ask for them alone.
routerosCheck :: IO ()
routerosCheck = do
  Instructions {..} <- getInstructions
  reportedAs <- asWritten instructionsScript
  script <- readFileAsUtf8 instructionsScript
  hosts <- readJson instructionsHosts
  chassis <- traverse readJson instructionsChassis
  vocabulary <- traverse (fmap vocabularyOfExport . readFileAsUtf8) instructionsExport
  let checkable =
        Checkable
          { checkableFile = reportedAs,
            checkableScript = script,
            checkableHosts = hosts,
            checkableChassis = chassis,
            checkableVocabulary = vocabulary
          }
  case checkScript checkable of
    Failure problems ->
      -- Only for the excerpts diagnose quotes back, and line endings rather
      -- than carriage returns, since dropping one mid-line would move every
      -- column after it.
      dieWithProblems stderr reportedAs (T.unpack (T.replace "\r\n" "\n" script)) problems
    Success () -> case splitAtWayBackIn reportedAs script of
      Nothing ->
        die "routeros-check: nothing wrong with this file and no way back into it either"
      Just (prefix, rest) -> do
        -- A command lost between the halves is one that would silently never
        -- reach the router.
        when (prefix <> rest /= script) $
          die "routeros-check: the halves do not add up to the file they came from"
        writeFileAsUtf8 (into [relfile|configuration.rsc|]) script
        writeFileAsUtf8 (into [relfile|prefix.rsc|]) prefix
        writeFileAsUtf8 (into [relfile|rest.rsc|]) rest
        writeFileAsUtf8 (into [relfile|problems.txt|]) $
          T.pack (unlines (map problemCodeText allProblemCodes))
      where
        into name = instructionsOutputDir </> name

readJson :: (FromJSON a) => Path Abs File -> IO a
readJson path = do
  decoded <- eitherDecodeFileStrict (fromAbsFile path)
  case decoded of
    Left err -> die (unwords ["could not read", concat [fromAbsFile path, ":"], err])
    Right value -> pure value

asWritten :: Path Abs File -> IO (SomeBase File)
asWritten path = do
  here <- getCurrentDir
  pure $ maybe (Abs path) Rel (stripProperPrefix here path)
