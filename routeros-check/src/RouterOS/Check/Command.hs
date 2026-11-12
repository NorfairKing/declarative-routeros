{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The little of this language these files use, and no substitute for a
-- RouterOS parser.
module RouterOS.Check.Command
  ( Command (..),
    SlashLine (..),
    commandLine,
    knownVerbs,
    parseScript,
    slashLine,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isSpace)
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

-- | The commands this checker knows how to check, unlike 'commandWords'.
knownVerbs :: [Text]
knownVerbs = ["add", "set", "remove"]

-- | The language is line oriented, and comments are dropped.
-- A line starting with a slash moves the section only when it is nothing but
-- a menu, as 'slashLine' tells.
-- Every other line is a command in the section.
-- A blank line ends an @[untried]@ annotation's reach, so it always sits
-- against what it excuses.
-- [check:ref ReadingOfAFile]
parseScript :: SomeBase File -> Text -> [Command]
parseScript file =
  let go :: Text -> Maybe Text -> [(Int, Text)] -> [Command]
      go section untried = \case
        [] -> []
        (number, raw) : rest ->
          let body = T.strip raw
              commandAt :: Text -> Int -> Command
              commandAt menu verbAt =
                let lineSpan = spanOfLine file number raw
                    (verb, remainder) = T.break isSpace (T.drop verbAt body)
                 in Command
                      { commandSection = menu,
                        commandSpan = lineSpan,
                        commandVerb = Located (spanWithin lineSpan verbAt (T.length verb)) verb,
                        commandRest = T.strip remainder,
                        commandArgs = parseArgs lineSpan (verbAt + T.length verb) remainder,
                        commandUntried = untried
                      }
           in case lineKind body of
                BlankLine -> go section Nothing rest
                CommentLine -> go section (untriedIn body <|> untried) rest
                StartsWithSlash (OnlyMenu menu) -> go menu untried rest
                StartsWithSlash (CommandInMenu menu verbAt) ->
                  commandAt menu verbAt : go section Nothing rest
                StartsWithSlash (CommandAtRoot verbAt) ->
                  commandAt "" verbAt : go section Nothing rest
                CommandLine -> commandAt section 0 : go section Nothing rest
   in go "" Nothing . zip [1 ..] . T.lines

data LineKind
  = BlankLine
  | CommentLine
  | StartsWithSlash !SlashLine
  | CommandLine

lineKind :: Text -> LineKind
lineKind body
  | T.null body = BlankLine
  | "#" `T.isPrefixOf` body = CommentLine
  | "/" `T.isPrefixOf` body = StartsWithSlash (slashLine body)
  | otherwise = CommandLine

-- | What a line starting with a slash does to the menu the lines after it are
-- in, which is what the router's own highlighter makes of it.
data SlashLine
  = -- | Nothing but a menu, which the lines after it are in.
    OnlyMenu !Text
  | -- | A command in the menu it names, with where in the line its verb starts.
    -- The lines after it stay in the menu that was open before it.
    CommandInMenu !Text !Int
  | -- | A command of the root menu, with where in the line its verb starts.
    -- The lines after it stay in the menu that was open before it.
    CommandAtRoot !Int
  deriving (Show, Eq)

-- | The verb is the first word after the slash that is a command word, and
-- everything after it is its arguments.
-- A line with no command word is only a menu.
slashLine :: Text -> SlashLine
slashLine body =
  let afterSlash = map (\(at, word) -> (at + 1, word)) (wordsWithOffsets (T.drop 1 body))
   in case break ((`elem` commandWords) . snd) afterSlash of
        (menu, []) -> OnlyMenu (T.unwords (map snd menu))
        ([], (verbAt, _) : _) -> CommandAtRoot verbAt
        (menu@(_ : _), (verbAt, _) : _) -> CommandInMenu (T.unwords (map snd menu)) verbAt

-- | Words that make a line starting with a slash a command rather than a menu.
-- Mostly what nearly every menu can do to its items, plus what a file writes
-- on a menu's own line to act on the menu as a whole, such as rebooting.
-- A menu named like one of them would read as a command, which is why this
-- is not every command there is.
-- Separate from 'knownVerbs' because recognising a command is not knowing how
-- to check it: what is not checked is reported rather than misread.
commandWords :: [Text]
commandWords =
  [ "add",
    "comment",
    "disable",
    "edit",
    "enable",
    "export",
    "find",
    "get",
    "import",
    "monitor",
    "move",
    "print",
    "reboot",
    "remove",
    "reset",
    "reset-configuration",
    "run",
    "set",
    "shutdown",
    "unset"
  ]

-- | Each word of a line with where it starts.
wordsWithOffsets :: Text -> [(Int, Text)]
wordsWithOffsets =
  let go :: Int -> Text -> [(Int, Text)]
      go here text =
        let (spaces, fromWord) = T.span isSpace text
            (word, after) = T.break isSpace fromWord
            start = here + T.length spaces
         in if T.null word then [] else (start, word) : go (start + T.length word) after
   in go 0

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
