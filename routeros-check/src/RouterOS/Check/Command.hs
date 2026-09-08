{-# LANGUAGE OverloadedStrings #-}

-- | The little of this language these files use, and no substitute for a
-- RouterOS parser.
module RouterOS.Check.Command
  ( Command (..),
    commandLine,
    parseScript,
  )
where

import Control.Applicative ((<|>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Path
import RouterOS.Check.Location

data Command = Command
  { commandSection :: !Text,
    commandSpan :: !SourceSpan,
    commandVerb :: !(Located Text),
    -- | A selector such as @[ find ... ]@ is what makes a command able to fail.
    commandRest :: !Text,
    commandArgs :: !(Map Text (Located Text)),
    -- | How a file says it knows the router has never been asked this.
    commandUntried :: !(Maybe Text)
  }

commandLine :: Command -> Int
commandLine = sourcePositionLine . sourceSpanBegin . commandSpan

-- | The language is line oriented: a line starting with a slash opens a
-- section, every other line is a command belonging to it, and comments are
-- dropped. A blank line ends an @[untried]@ annotation's reach, so it always
-- sits against what it excuses.
parseScript :: SomeBase File -> Text -> [Command]
parseScript file = go "" Nothing . zip [1 ..] . T.lines
  where
    go _ _ [] = []
    go section untried ((number, raw) : rest)
      | T.null body = go section Nothing rest
      | "#" `T.isPrefixOf` body = go section (untriedIn body <|> untried) rest
      | "/" `T.isPrefixOf` body = go (T.strip (T.drop 1 body)) untried rest
      | otherwise =
          let lineSpan = spanOfLine file number raw
              (verb, remainder) = T.break (== ' ') body
           in Command
                { commandSection = section,
                  commandSpan = lineSpan,
                  commandVerb = Located (spanWithin lineSpan 0 (T.length verb)) verb,
                  commandRest = T.strip remainder,
                  commandArgs = parseArgs lineSpan (T.length verb) remainder,
                  commandUntried = untried
                }
                : go section Nothing rest
      where
        body = T.strip raw

-- | Allowed to come out empty, so an annotation without a reason is complained
-- about rather than quietly accepted.
untriedIn :: Text -> Maybe Text
untriedIn comment = T.strip <$> T.stripPrefix marker (snd (T.breakOn marker comment))
  where
    marker = "[untried]"

parseArgs :: SourceSpan -> Int -> Text -> Map Text (Located Text)
parseArgs lineSpan verbLength remainder =
  Map.fromList (mapMaybe pair (splitArgs remainder))
  where
    pair (offset, chunk) = case T.breakOn "=" chunk of
      (key, rest)
        | T.null rest -> Nothing
        | otherwise ->
            let quoted = T.drop 1 rest
                value = unquote quoted
                -- Unquoting takes one from each end or neither.
                openingQuote = if T.length quoted == T.length value then 0 else 1
                -- Past the verb, the key, the "=" and that quote.
                valueOffset = verbLength + offset + T.length key + 1 + openingQuote
             in Just
                  ( T.strip key,
                    Located (spanWithin lineSpan valueOffset (T.length value)) value
                  )
    unquote value = fromMaybe value (T.stripPrefix "\"" value >>= T.stripSuffix "\"")

splitArgs :: Text -> [(Int, Text)]
splitArgs = go 0 False "" 0 . T.unpack
  where
    go start _ current _ [] = [(start, T.pack (reverse current))]
    go start inQuotes current here (c : cs)
      | c == '"' = go start (not inQuotes) (c : current) (here + 1) cs
      | c == ' ' && not inQuotes =
          (start, T.pack (reverse current)) : go (here + 1) False "" (here + 1) cs
      | otherwise = go start inQuotes (c : current) (here + 1) cs
