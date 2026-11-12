{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module RouterOS.CheckSpec (spec) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
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
import Test.QuickCheck (Gen, elements, forAll, listOf, listOf1)
import Test.Syd

spec :: Spec
spec = do
  describe "problemCodeText" $
    it "spells a code the way its example is named" $
      map problemCodeText [CodeDuplicateLeaseMac, CodeHostForwardMissing]
        `shouldBe` ["duplicate-lease-mac", "host-forward-missing"]

  describe "slashLine" $ do
    it "reads the root menu on its own as a menu" $
      slashLine "/" `shouldBe` OnlyMenu ""

    it "reads a menu on its own as a menu" $
      slashLine "/ip firewall nat" `shouldBe` OnlyMenu "ip firewall nat"

    it "reads a menu without a command word as a menu" $
      slashLine "/tool fetch url=http://example.com" `shouldBe` OnlyMenu "tool fetch url=http://example.com"

    it "finds the menu and the verb before the arguments" $
      slashLine "/tool netwatch add type=dns dns-server=1.1.1.1"
        `shouldBe` CommandInMenu "tool netwatch" 15

    it "finds the verb before a selector" $
      slashLine "/interface ethernet set [ find default-name=sfp28-2 ] fec-mode=off"
        `shouldBe` CommandInMenu "interface ethernet" 20

    it "finds a verb without arguments" $
      slashLine "/system reboot" `shouldBe` CommandInMenu "system" 8

    it "finds the first command word as the verb" $
      slashLine "/ip firewall filter disable [ find comment=x ]" `shouldBe` CommandInMenu "ip firewall filter" 20

    it "reads a command right after the slash as a command of the root menu" $
      slashLine "/import file=configuration.rsc" `shouldBe` CommandAtRoot 1

  describe "parseScript" $ do
    it "puts the lines after a menu on its own in that menu" $
      map shapeOf (parseScript scriptFile "/ip firewall nat\nadd chain=srcnat action=masquerade\n")
        `shouldBe` [("ip firewall nat", "add", [("action", "masquerade"), ("chain", "srcnat")])]

    it "leaves the lines after a command on its menu's line in the menu open before it" $
      map shapeOf (parseScript scriptFile "/ip dhcp-server network\n/ip firewall filter add chain=forward\nadd address=192.168.99.0/24\n")
        `shouldBe` [ ("ip firewall filter", "add", [("chain", "forward")]),
                     ("ip dhcp-server network", "add", [("address", "192.168.99.0/24")])
                   ]

    it "reads a command of the root menu without leaving the menu open before it" $
      map shapeOf (parseScript scriptFile "/ip firewall nat\n/import file=x.rsc\nadd chain=srcnat action=masquerade\n")
        `shouldBe` [ ("", "import", [("file", "x.rsc")]),
                     ("ip firewall nat", "add", [("action", "masquerade"), ("chain", "srcnat")])
                   ]

    it "reads a command without arguments without leaving the menu open before it" $
      map shapeOf (parseScript scriptFile "/ip firewall nat\n/system reboot\nadd chain=srcnat action=masquerade\n")
        `shouldBe` [ ("system", "reboot", []),
                     ("ip firewall nat", "add", [("action", "masquerade"), ("chain", "srcnat")])
                   ]

    it "reads a printing command as a command" $
      map shapeOf (parseScript scriptFile "/ip address print\n")
        `shouldBe` [("ip address", "print", [])]

    it "reads an unnamed argument as an argument rather than the verb" $
      map shapeOf (parseScript scriptFile "/interface ethernet set ether1 mtu=1500\n")
        `shouldBe` [("interface ethernet", "set", [("mtu", "1500")])]

    it "reads a number as an argument rather than the verb" $
      map shapeOf (parseScript scriptFile "/ip firewall filter move 3 destination=0\n")
        `shouldBe` [("ip firewall filter", "move", [("destination", "0")])]

    it "reads only an unnamed argument as an argument" $
      map shapeOf (parseScript scriptFile "/interface bridge port remove 0\n")
        `shouldBe` [("interface bridge port", "remove", [])]

    it "reads a where clause as arguments rather than the verb" $
      map shapeOf (parseScript scriptFile "/ip address print where interface=ether1\n")
        `shouldBe` [("ip address", "print", [("interface", "ether1")])]

    it "reads a negated flag as an argument rather than the verb" $
      map shapeOf (parseScript scriptFile "/ip firewall filter add !disabled chain=x\n")
        `shouldBe` [("ip firewall filter", "add", [("chain", "x")])]

    it "reads a quoted argument as an argument rather than the verb" $
      map shapeOf (parseScript scriptFile "/system script run \"x\"\n")
        `shouldBe` [("system script", "run", [])]

    it "ends the verb at a tab as it does at a space" $
      map shapeOf (parseScript scriptFile "/tool netwatch add\ttype=dns\n")
        `shouldBe` [("tool netwatch", "add", [("type", "dns")])]

    it "reads a command on its menu's line as it reads it on the line after its menu" $
      forAll ((,,) <$> genMenu <*> genSeparator <*> genCommandText) $ \(menu, separator, command) ->
        map shapeOf (parseScript scriptFile (T.concat ["/", menu, separator, command, "\n"]))
          `shouldBe` map shapeOf (parseScript scriptFile (T.concat ["/", menu, "\n", command, "\n"]))

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

scriptFile :: SomeBase File
scriptFile = Rel [relfile|script.rsc|]

-- | What a command means, without where it was written.
shapeOf :: Command -> (T.Text, T.Text, [(T.Text, T.Text)])
shapeOf command =
  ( commandSection command,
    locatedValue (commandVerb command),
    Map.toList (Map.map locatedValue (commandArgs command))
  )

-- | Menus made only of words that are no command anywhere.
genMenu :: Gen T.Text
genMenu =
  T.unwords
    <$> listOf1 (elements ["ip", "firewall", "filter", "nat", "interface", "bridge", "port", "tool", "netwatch", "dhcp-server", "lease"])

genSeparator :: Gen T.Text
genSeparator = elements [" ", "\t", "  "]

genCommandText :: Gen T.Text
genCommandText = do
  verb <- elements ["add", "set", "remove", "print", "enable", "disable", "move"]
  unnamed <- listOf (elements ["0", "3", "ether1", "!disabled", "[ find ]"])
  arguments <- listOf genArgument
  pure (T.unwords (verb : unnamed ++ arguments))

genArgument :: Gen T.Text
genArgument = do
  key <- elements ["chain", "action", "name", "interface", "address", "comment"]
  value <- listOf1 (elements (concat [['a' .. 'z'], ['0' .. '9'], "./-"]))
  pure (T.pack (concat [key, "=", value]))

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
