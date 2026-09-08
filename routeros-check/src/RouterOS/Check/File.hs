-- | Utf-8 whatever the locale says. A nix build names no encoding, so with the
-- locale-dependent versions a configuration with a comment outside ascii would
-- fail to be read there and nowhere else.
module RouterOS.Check.File
  ( readFileAsUtf8,
    writeFileAsUtf8,
  )
where

import qualified Data.ByteString as SB
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Path

readFileAsUtf8 :: Path Abs File -> IO Text
readFileAsUtf8 path = do
  bytes <- SB.readFile (fromAbsFile path)
  case TE.decodeUtf8' bytes of
    Left complaint -> fail (unwords [concat [fromAbsFile path, ":"], "not utf-8:", show complaint])
    Right text -> pure text

writeFileAsUtf8 :: Path Abs File -> Text -> IO ()
writeFileAsUtf8 path = SB.writeFile (fromAbsFile path) . TE.encodeUtf8
