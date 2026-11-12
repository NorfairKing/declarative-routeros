{-# LANGUAGE OverloadedStrings #-}

-- | Which arm64 CHR images MikroTik builds, for the vm test to pick the one
-- nearest a router's RouterOS from.
-- MikroTik publishes no list of them, so this asks for each release in turn.
module RouterOS.Images
  ( updateChrImages,
    Version (..),
    Sha256 (..),
    Image (..),
    Probe (..),
    releaseText,
    imageOf,
    checksumUrlOf,
    nextToProbe,
    parseChecksum,
    parseNewest,
    renderImages,
  )
where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson.Encode.Pretty as Pretty
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Lazy as LB
import Data.Char (isDigit, isHexDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseStatus)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Exit (die)
import Text.Read (readMaybe)

-- | Prints the images MikroTik builds as JSON, for @nix/chr-images.json@.
-- Fails rather than print a list that may be missing an image that is there.
updateChrImages :: IO ()
updateChrImages = do
  manager <- newTlsManager
  newestAnswer <- fetch manager newestStableUrl
  newest <- case newestAnswer of
    Just answer -> case parseNewest answer of
      Left complaint -> die complaint
      Right version -> pure version
    Nothing -> die (unwords [newestStableUrl, "is not there"])
  images <- concat <$> mapM (probeMinor manager []) [1 .. versionMinor newest]
  let byVersion = Map.fromList [(releaseText version, image) | (version, image) <- images]
  if Map.member (releaseText newest) byVersion
    then LB.putStr (renderImages byVersion)
    else die (concat ["MikroTik's newest stable RouterOS, ", T.unpack (releaseText newest), ", has no arm64 image"])

newestStableUrl :: String
newestStableUrl = "https://upgrade.mikrotik.com/routeros/NEWESTa7.stable"

probeMinor :: Manager -> [Probe] -> Int -> IO [(Version, Image)]
probeMinor manager probed minor =
  case nextToProbe minor probed of
    Nothing -> pure []
    Just version -> do
      answer <- fetch manager (T.unpack (checksumUrlOf version))
      case answer of
        Nothing -> probeMinor manager (probed ++ [Missing]) minor
        Just checksum -> case parseChecksum version checksum of
          Left complaint -> die complaint
          Right sha256 -> do
            let image = imageOf version sha256
            ((version, image) :) <$> probeMinor manager (probed ++ [Found]) minor

-- | 'Nothing' for a 404, since that is how MikroTik says there is no such file.
-- Anything else that is not a 200 might be a file that is there, so it is fatal.
fetch :: Manager -> String -> IO (Maybe Text)
fetch manager url = do
  request <- parseRequest url
  response <- httpLbs request manager
  case statusCode (responseStatus response) of
    200 -> pure (Just (TE.decodeUtf8With TE.lenientDecode (LB.toStrict (responseBody response))))
    404 -> pure Nothing
    code -> die (unwords [url, "answered", show code])

-- | A RouterOS 7 release: its minor version and its patch, where patch 0 is
-- the release named without one, like @7.15@.
data Version = Version
  { versionMinor :: !Int,
    versionPatch :: !Int
  }
  deriving (Show, Eq, Ord)

newtype Sha256 = Sha256 {sha256Text :: Text}
  deriving (Show, Eq)

data Image = Image
  { imageUrl :: !Text,
    imageSha256 :: !Sha256
  }
  deriving (Show, Eq)

data Probe = Found | Missing
  deriving (Show, Eq)

releaseText :: Version -> Text
releaseText version =
  T.pack $
    concat
      [ "7.",
        show (versionMinor version),
        if versionPatch version == 0 then "" else concat [".", show (versionPatch version)]
      ]

imageOf :: Version -> Sha256 -> Image
imageOf version sha256 =
  Image
    { imageUrl = imageUrlOf version,
      imageSha256 = sha256
    }

imageUrlOf :: Version -> Text
imageUrlOf version =
  T.concat
    [ "https://download.mikrotik.com/routeros/",
      releaseText version,
      "/",
      imageFileOf version
    ]

imageFileOf :: Version -> Text
imageFileOf version = T.concat ["chr-", releaseText version, "-arm64.img.zip"]

checksumUrlOf :: Version -> Text
checksumUrlOf version = T.concat [imageUrlOf version, ".sha256"]

-- | The next release of a minor version to ask about, given what the ones
-- before it turned out to be, or 'Nothing' after two missing in a row.
-- Two, so that one release without an image does not end the list early.
nextToProbe :: Int -> [Probe] -> Maybe Version
nextToProbe minor probed =
  if take 2 (reverse probed) == [Missing, Missing]
    then Nothing
    else
      Just
        Version
          { versionMinor = minor,
            versionPatch = length probed
          }

-- | MikroTik's checksum files read @<sha256>  <file name>@.
-- The name is checked so a checksum is never recorded for some other file.
parseChecksum :: Version -> Text -> Either String Sha256
parseChecksum version answer =
  case T.words answer of
    [sha256, name]
      | name == imageFileOf version,
        T.length sha256 == 64,
        T.all isHexDigit sha256 ->
          Right (Sha256 (T.toLower sha256))
    _ ->
      Left
        ( unwords
            [ "expected a sha256 of",
              concat [T.unpack (imageFileOf version), ","],
              "got",
              show (T.strip answer)
            ]
        )

-- | MikroTik's answer reads @<version> <release time>@.
parseNewest :: Text -> Either String Version
parseNewest answer =
  let number :: Text -> Maybe Int
      number digits = if T.all isDigit digits then readMaybe (T.unpack digits) else Nothing
      parsed = case T.splitOn "." <$> take 1 (T.words answer) of
        [["7", minor]] -> Version <$> number minor <*> pure 0
        [["7", minor, patch]] -> Version <$> number minor <*> number patch
        _ -> Nothing
   in maybe (Left (unwords ["expected a RouterOS 7 release, got", show (T.strip answer)])) Right parsed

-- | Keys in order and two spaces of indentation, so a refresh only shows what
-- MikroTik changed.
renderImages :: Map Text Image -> LB.ByteString
renderImages images =
  let config =
        Pretty.defConfig
          { Pretty.confIndent = Pretty.Spaces 2,
            Pretty.confCompare = compare
          }
   in LB.concat
        [ Pretty.encodePretty' config (object [Key.fromText version .= imageValue image | (version, image) <- Map.toList images]),
          "\n"
        ]

imageValue :: Image -> Value
imageValue image =
  object
    [ "url" .= imageUrl image,
      "sha256" .= sha256Text (imageSha256 image)
    ]
