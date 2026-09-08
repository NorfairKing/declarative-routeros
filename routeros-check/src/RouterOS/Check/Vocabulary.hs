{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Which words a particular router knows. The router printed these commands
-- itself, which is proof it accepts them, and a verbose export prints every
-- parameter at its default too, which tells a name the router does not know
-- from one it merely has no use for.
module RouterOS.Check.Vocabulary
  ( Vocabulary,
    vocabularyOfExport,
    knownMenu,
    knownParameters,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Path
import RouterOS.Check.Command
import RouterOS.Check.Location

newtype Vocabulary = Vocabulary (Map Text (Map Text (Set Text)))

knownMenu :: Vocabulary -> Text -> Bool
knownMenu (Vocabulary menus) menu = Map.member menu menus

knownParameters :: Vocabulary -> Text -> Text -> Maybe (Set Text)
knownParameters (Vocabulary menus) menu verb = Map.lookup menu menus >>= Map.lookup verb

vocabularyOfExport :: Text -> Vocabulary
vocabularyOfExport export =
  Vocabulary $
    Map.fromListWith
      (Map.unionWith Set.union)
      [ ( commandSection command,
          Map.singleton
            (locatedValue (commandVerb command))
            (Map.keysSet (commandArgs command))
        )
      | -- Nothing here is ever pointed at, only asked whether it contains a
        -- word, so the spans go with the file name and the line numbers.
        command <- parseScript (Rel [relfile|export.rsc|]) (T.unlines (unwrapped export))
      ]

-- | An export wraps mid-token at eighty columns with a trailing backslash, so
-- the indent on the next line is part of no value.
unwrapped :: Text -> [Text]
unwrapped = go . map stripCarriage . T.lines
  where
    stripCarriage line = fromMaybe line (T.stripSuffix "\r" line)

    go [] = []
    go (line : rest) = case T.stripSuffix "\\" line of
      Nothing -> line : go rest
      Just beginning -> case rest of
        [] -> [beginning]
        (next : more) -> go (T.append beginning (T.stripStart next) : more)
