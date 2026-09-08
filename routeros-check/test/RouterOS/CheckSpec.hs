{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module RouterOS.CheckSpec (spec) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Path
import Path.IO
import RouterOS.Check
import RouterOS.Check.Command
import RouterOS.Check.File
import RouterOS.Check.Location
import RouterOS.Check.Problem
import RouterOS.Check.Validation
import RouterOS.Check.Vocabulary
import System.Environment (lookupEnv)
import Test.Syd

spec :: Spec
spec = do
  describe "problemCodeText" $
    it "spells a code the way its example is named" $
      map problemCodeText [CodeDuplicateLeaseMac, CodeHostForwardMissing]
        `shouldBe` ["duplicate-lease-mac", "host-forward-missing"]

  describe "checkScript" $ do
    it "has an example named after every problem it can find" $ do
      dir <- examplesDir
      (_, files) <- listDir (dir </> [reldir|caught-by-check|])
      let haveExamples = map (stem . filename) (scriptsAmong files)
      filter (`notElem` haveExamples) (map problemCodeText allProblemCodes) `shouldBe` []

    describe "reports every problem in the examples of it" $
      eachExample [reldir|caught-by-check|] $ \script ->
        it (unwords [named script, "reads as its golden output does"]) $
          goldenTextFile (fromAbsFile (goldenFor script)) $ do
            checkable <- checkableFor script
            case checkScript checkable of
              Success () -> expectationFailure (unwords [named script, "was clean, so there is no report"])
              Failure problems -> pure (report script (checkableScript checkable) problems)

    describe "says nothing about a working configuration" $ do
      eachExample [reldir|valid|] $ \script ->
        it (named script) $ shouldBeClean script
      eachExample [reldir|deployable|] $ \script ->
        it (named script) $ shouldBeClean script
      -- These pass on purpose: they are what only the vm test can catch.
      eachExample [reldir|caught-by-vmtest|] $ \script ->
        it (unwords [named script, "is for the vm test to catch, not this"]) $
          shouldBeClean script

  describe "splitAtWayBackIn" $
    describe "cuts a file into halves that are the halves" $
      mapM_
        ( \subdir -> eachExample subdir $ \script ->
            it (named script) $ do
              checkable <- checkableFor script
              case splitAtWayBackIn (Rel (filename script)) (checkableScript checkable) of
                Nothing ->
                  expectationFailure (unwords [named script, "has no way back into the router"])
                Just (prefix, rest) ->
                  prefix <> rest `shouldBe` checkableScript checkable
        )
        [[reldir|valid|], [reldir|deployable|]]

  -- The half paired with the reset is where the dhcp server is, and one without
  -- its leases hands out pool addresses instead.
  describe "puts every static lease in the half that is paired with the reset" $
    mapM_
      ( \subdir -> eachExample subdir $ \script ->
          it (named script) $ do
            checkable <- checkableFor script
            case splitAtWayBackIn (Rel (filename script)) (checkableScript checkable) of
              Nothing ->
                expectationFailure (unwords [named script, "has no way back into the router"])
              Just (prefix, _) ->
                leasesIn (Rel (filename script)) prefix
                  `shouldBe` leasesIn (Rel (filename script)) (checkableScript checkable)
      )
      [[reldir|valid|], [reldir|deployable|]]

-- | The examples live above this package because the vm test uses them too.
examplesDir :: IO (Path Abs Dir)
examplesDir = do
  set <- lookupEnv "ROUTEROS_CHECK_EXAMPLES"
  resolveDir' (fromMaybe "../examples" set)

eachExample :: Path Rel Dir -> (Path Abs File -> TestDefM outers () ()) -> TestDefM outers () ()
eachExample subdir act = do
  dir <- runIO examplesDir
  (_, files) <- runIO (listDir (dir </> subdir))
  mapM_ act (sort (scriptsAmong files))

scriptsAmong :: [Path Abs File] -> [Path Abs File]
scriptsAmong = filter ((== Just ".rsc") . fileExtension)

named :: Path Abs File -> String
named = fromRelFile . filename

stem :: Path Rel File -> String
stem name = maybe (fromRelFile name) (fromRelFile . fst) (splitExtension name)

goldenFor :: Path Abs File -> Path Abs File
goldenFor script = fromMaybe script (replaceExtension ".golden" script)

-- | The hosts, the chassis and the export are the example's own files if it has
-- them and the shared ones otherwise, so an example about a router says what is
-- different about that router and nothing else.
checkableFor :: Path Abs File -> IO Checkable
checkableFor script = do
  text <- readFileAsUtf8 script
  hosts <- readJson =<< ownOrShared script "-hosts.json" [relfile|hosts.json|]
  chassis <- readJson =<< ownOrShared script "-chassis.json" [relfile|chassis.json|]
  vocabulary <-
    vocabularyOfExport
      <$> (readFileAsUtf8 =<< ownOrShared script "-export.rsc" [relfile|export.rsc|])
  pure
    Checkable
      { checkableFile = Rel (filename script),
        checkableScript = text,
        checkableHosts = hosts,
        checkableChassis = Just chassis,
        checkableVocabulary = Just vocabulary
      }

ownOrShared :: Path Abs File -> String -> Path Rel File -> IO (Path Abs File)
ownOrShared script suffix shared = do
  (withoutExtension, _) <- splitExtension script
  own <- parseAbsFile (concat [fromAbsFile withoutExtension, suffix])
  ownExists <- doesFileExist own
  if ownExists
    then pure own
    else do
      dir <- examplesDir
      pure (dir </> shared)

readJson :: (FromJSON a) => Path Abs File -> IO a
readJson path = do
  decoded <- eitherDecodeFileStrict (fromAbsFile path)
  case decoded of
    Left err -> fail (unwords [concat [fromAbsFile path, ":"], err])
    Right value -> pure value

shouldBeClean :: Path Abs File -> IO ()
shouldBeClean script = do
  checkable <- checkableFor script
  case checkScript checkable of
    Success () -> pure ()
    Failure problems ->
      expectationFailure (T.unpack (report script (checkableScript checkable) problems))

report :: Path Abs File -> T.Text -> NonEmpty Problem -> T.Text
report script text =
  renderProblems (Rel (filename script)) (T.unpack (T.replace "\r\n" "\n" text))

leasesIn :: SomeBase File -> T.Text -> Int
leasesIn file text =
  length
    [ command
    | command <- parseScript file text,
      commandSection command == "ip dhcp-server lease",
      locatedValue (commandVerb command) == "add"
    ]
