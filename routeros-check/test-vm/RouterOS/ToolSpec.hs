{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- | The one path in this repository that a vm importing over its own console
-- never touches. RouterOS prints nothing about an import run over ssh, though
-- the same command on a console prints every line it applied, and it accepts a
-- connection well before it will authenticate one.
module RouterOS.ToolSpec (spec) where

import Control.Exception.Safe (bracket, catchAny, displayException, finally, throwIO, tryAny)
import Control.Monad (when)
import Data.Aeson (encodeFile, object, (.=))
import Data.Foldable (for_)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Network.Socket
import Path
import Path.IO
import RouterOS.Check.File (writeFileAsUtf8)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit
import System.IO
import System.Process
import System.Timeout (timeout)
import Test.Syd

spec :: Spec
spec = withoutTimeout $
  describe "over ssh, against a router that is up" $
    around withRouter $ do
      it "imports a file, and says that it did" $ \router -> do
        configuration <- exampleFile [relfile|valid/minimal.rsc|]
        shouldSucceed "the import"
          =<< tool (["import"] <> reach router <> [fromAbsFile configuration])

      it "resets into one half, waits, and imports the other onto what came up" $ \router -> do
        halves <- checkedHalvesOf [reldir|reachable|]
        shouldSucceed "the reset"
          =<< tool
            (["reset-into"] <> reach router <> [fromAbsFile (halves </> [relfile|prefix.rsc|])])
        shouldSucceed "waiting for the router" =<< tool (["wait"] <> reach router)
        shouldSucceed "the second stage"
          =<< tool
            (["import"] <> reach router <> [fromAbsFile (halves </> [relfile|rest.rsc|])])

      -- The one command that ever runs against a router anybody owns.
      it "applies both halves and records what the router became" $ \router -> do
        halves <- checkedHalvesOf [reldir|reachable|]
        withSystemTempDir "routeros-applied" $ \record -> do
          -- For this router, whatever it says about itself right now.
          shouldSucceed "reading the router first"
            =<< tool (["download"] <> reach router <> ["--into", fromAbsDir record])
          settings <-
            settingsFor
              router
              record
              (halves </> [relfile|prefix.rsc|])
              (halves </> [relfile|rest.rsc|])
              record
          shouldSucceed "applying both halves"
            =<< tool ["router", "--settings", fromAbsFile settings, "--yes"]
          -- A record missing one is a check that does not run the next time.
          for_
            [ [relfile|export.rsc|],
              [relfile|export-verbose.rsc|],
              [relfile|chassis.json|]
            ]
            $ \name -> do
              written <- doesFileExist (record </> name)
              when (not written) $
                expectationFailure (unwords [fromRelFile name, "was not recorded"])

      -- The router it is checked against has to be the router, or the staleness
      -- gate fires first and this passes for a reason it is not testing.
      it "refuses a half that is not there, rather than deploying the other one" $ \router -> do
        halves <- checkedHalvesOf [reldir|reachable|]
        withSystemTempDir "routeros-applied" $ \record -> do
          shouldSucceed "reading the router first"
            =<< tool (["download"] <> reach router <> ["--into", fromAbsDir record])
          settings <-
            settingsFor
              router
              record
              (halves </> [relfile|prefix.rsc|])
              (record </> [relfile|there-is-no-such-half.rsc|])
              record
          (code, output) <-
            tool ["router", "--settings", fromAbsFile settings, "--yes"]
          case code of
            ExitSuccess ->
              expectationFailure
                (unlines ["it deployed anyway, with half the configuration missing:", output])
            ExitFailure _ ->
              when (not ("there-is-no-such-half.rsc" `isInfixOf` output)) $
                expectationFailure
                  (unlines ["it stopped, but not over the missing half:", output])

      it "refuses a router that is not the one the checks read" $ \router -> do
        halves <- checkedHalvesOf [reldir|reachable|]
        withSystemTempDir "routeros-applied" $ \record -> do
          -- No export in the record, so what it was checked against is not this
          -- router.
          settings <-
            settingsFor
              router
              record
              (halves </> [relfile|prefix.rsc|])
              (halves </> [relfile|rest.rsc|])
              record
          writeFileAsUtf8 (record </> [relfile|export-verbose.rsc|]) "not this router"
          (code, output) <-
            tool ["router", "--settings", fromAbsFile settings, "--yes"]
          case code of
            ExitSuccess ->
              expectationFailure (unlines ["it deployed against a router it had not read:", output])
            ExitFailure _ -> do
              when (not ("download" `isInfixOf` output)) $
                expectationFailure
                  (unlines ["it stopped without saying how to fix it:", output])
              recorded <- doesFileExist (record </> [relfile|export.rsc|])
              when recorded $
                expectationFailure "it recorded a deployment it refused to do"

settingsFor :: Router -> Path Abs Dir -> Path Abs File -> Path Abs File -> Path Abs Dir -> IO (Path Abs File)
settingsFor router record prefix rest recordInto = do
  let file = record </> [relfile|router.json|]
  encodeFile
    (fromAbsFile file)
    ( object
        [ "name" .= ("held" :: String),
          "username" .= ("admin" :: String),
          "address" .= ("127.0.0.1" :: String),
          "port" .= toInteger (routerPort router),
          "prefix" .= fromAbsFile prefix,
          "rest" .= fromAbsFile rest,
          "checkedAgainst" .= fromAbsFile (record </> [relfile|export-verbose.rsc|]),
          "recordInto" .= fromAbsDir recordInto
        ]
    )
  pure file

shouldSucceed :: String -> (ExitCode, String) -> IO ()
shouldSucceed what (code, output) = case code of
  ExitSuccess -> pure ()
  ExitFailure status ->
    expectationFailure (unlines [unwords [what, "failed with exit code", concat [show status, ":"]], output])

data Router = Router
  { -- | What the router's ssh is forwarded to, since a vm on a user-mode
    -- network is reachable no other way.
    routerPort :: !PortNumber,
    -- | Anything written here brings it down.
    routerStop :: !Handle
  }

type Started = (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)

withRouter :: (Router -> IO ()) -> IO ()
withRouter act = do
  (router, started) <- boot triesForAPort
  act router `finally` shutDown router started

-- | A port is chosen by binding one and letting go of it, so between that and
-- qemu taking it something else can. Indistinguishable from a router that would
-- not boot, and both are answered by trying again somewhere else.
triesForAPort :: Int
triesForAPort = 3

boot :: Int -> IO (Router, Started)
boot triesLeft = do
  port <- freePort
  environment <- getEnvironment
  command <- resolveFile' . fromMaybe "../vmrouter" =<< lookupEnv "ROUTEROS_VMROUTER"
  let asked =
        (proc (fromAbsFile command) [])
          { std_in = CreatePipe,
            std_out = CreatePipe,
            env =
              Just $
                environment
                  <> [("VMTEST_SSHPORT", show port), ("VMTEST_HOLD", "1")]
          }
  started <- createProcess asked
  came <- tryAny (readiness port started)
  case came of
    Right router -> pure (router, started)
    Left complaint -> do
      cleanupProcess started
      if triesLeft > 1
        then do
          TIO.putStrLn
            (T.pack (unwords ["no router on port", concat [show port, ":"], displayException complaint]))
          boot (triesLeft - 1)
        else throwIO complaint

readiness :: PortNumber -> Started -> IO Router
readiness port started = case started of
  (Just toRouter, Just fromRouter, _, _) -> do
    -- Long, because this is a router booting under emulation.
    ready <- timeout (20 * 60 * 1000 * 1000) (waitUntilReady fromRouter)
    case ready of
      Just () -> pure (Router port toRouter)
      Nothing -> fail "the router never said it was ready for ssh"
  _ -> fail "the router started without the pipes it was asked for"

-- | Stopping an already-gone process would replace whatever a test was failing
-- about with a broken pipe.
shutDown :: Router -> Started -> IO ()
shutDown router started =
  told `catchAny` (\_ -> pure ()) `finally` cleanupProcess started
  where
    told = do
      hPutStrLn (routerStop router) "stop"
      hFlush (routerStop router)

waitUntilReady :: Handle -> IO ()
waitUntilReady fromRouter = do
  line <- TIO.hGetLine fromRouter
  TIO.putStrLn line
  if "ready for ssh" `T.isInfixOf` line then pure () else waitUntilReady fromRouter

-- | Bounded, though the tool itself waits for a router indefinitely on purpose:
-- a router that is never coming back is a test that never finishes, and one
-- that hangs takes the build's lock with it for as long as nobody notices.
tool :: [String] -> IO (ExitCode, String)
tool arguments = do
  environment <- getEnvironment
  let started =
        (proc "declarative-routeros" arguments)
          { env = Just (environment <> [("ROUTEROS_SSH_PASSWORD", "vmtest-password")])
          }
  finished <- timeout (20 * 60 * 1000 * 1000) (readCreateProcessWithExitCode started "")
  case finished of
    Nothing ->
      pure
        ( ExitFailure 1,
          unwords ("it never finished:" : "declarative-routeros" : arguments)
        )
    Just (code, out, err) -> pure (code, out <> err)

-- | Every subcommand but @router@ is told which router on the command line,
-- and the address is the first positional, so this goes before any file.
reach :: Router -> [String]
reach router = ["--username", "admin", "--port", show (routerPort router), "127.0.0.1"]

freePort :: IO PortNumber
freePort = bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
  bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  socketPort sock

exampleFile :: Path Rel File -> IO (Path Abs File)
exampleFile name = do
  dir <- resolveDir' . fromMaybe "../examples" =<< lookupEnv "ROUTEROS_CHECK_EXAMPLES"
  pure (dir </> name)

checkedHalvesOf :: Path Rel Dir -> IO (Path Abs Dir)
checkedHalvesOf name = do
  dir <- resolveDir' . fromMaybe "../checked" =<< lookupEnv "ROUTEROS_CHECKED"
  pure (dir </> name)
