{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A router can take every line of a file and still not end up as it says:
-- one command may undo another, and a script may change things afterwards.
-- The export is the router's own account of what it ended up with, and a
-- verbose one spells out every value, so every value a configuration gives can
-- be looked up in it.
module RouterOS.Postflight
  ( routerosPostflight,
    Outcome (..),
    postflight,
    Report (..),
    lookUp,
    reportOutcome,
    renderReport,
    Line (..),
    linesIn,
    Entry (..),
    entriesIn,
    Word (..),
    wordsOf,
    conditionsOf,
    missing,
    outOfOrder,
    unasked,
    leftOver,
    notLookedUp,
    sameValue,
    closestDifferences,
  )
where

import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isAscii, isDigit, isHexDigit, isSpace)
import Data.IP (IP)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TIO
import Data.Word (Word8)
import Path
import RouterOS.Check.Command (SlashLine (..), slashLine)
import RouterOS.Check.File (readFileAsUtf8)
import RouterOS.Postflight.OptParse
import System.Exit (exitFailure)
import System.IO (hIsTerminalDevice, stdout)
import Text.Colour (Chunk, TerminalCapabilities (..), brightBlack, chunk, fore, green, red, renderChunksText, unlinesChunks)
import Text.Read (readMaybe)
import Prelude hiding (Word)

routerosPostflight :: IO ()
routerosPostflight = do
  instructions <- getInstructions
  outcome <- postflight (instructionsConfiguration instructions) (instructionsExport instructions)
  case outcome of
    AsConfigured -> pure ()
    NotAsConfigured -> exitFailure

data Outcome
  = AsConfigured
  | NotAsConfigured
  deriving (Show, Eq)

postflight :: [Path Abs File] -> Path Abs File -> IO Outcome
postflight configuration export = do
  asked <- concat <$> mapM (\file -> entriesIn (Abs file) <$> readFileAsUtf8 file) configuration
  has <- entriesIn (Abs export) <$> readFileAsUtf8 export
  let report = lookUp asked has
  terminal <- hIsTerminalDevice stdout
  let capabilities = if terminal then With8Colours else WithoutColours
  TIO.putStr (renderChunksText capabilities (unlinesChunks (renderReport report)))
  pure (reportOutcome report)

-- | Everything looking a configuration up in a router's export finds.
data Report = Report
  { reportLookedUp :: !Int,
    -- | With how the closest of what the router has differs.
    reportMissing :: ![(Entry, [Text])],
    -- | With what the router has after it, that the configuration put first.
    reportOutOfOrder :: ![(Entry, Entry)],
    reportUnasked :: ![Entry],
    -- | With what the router still has that it picks out.
    reportLeftOver :: ![(Entry, Entry)],
    reportNotLookedUp :: !(Map Text Int)
  }
  deriving (Show, Eq)

lookUp :: [Entry] -> [Entry] -> Report
lookUp asked has =
  Report
    { reportLookedUp = length (filter comparable asked),
      reportMissing = [(entry, closestDifferences entry has) | entry <- missing asked has],
      reportOutOfOrder = outOfOrder asked has,
      reportUnasked = unasked asked has,
      reportLeftOver = leftOver asked has,
      reportNotLookedUp = notLookedUp asked
    }

-- | What was not looked up only says how much the rest covers.
reportOutcome :: Report -> Outcome
reportOutcome = \case
  Report _ lacking misplaced extra remaining _ ->
    if null lacking && null misplaced && null extra && null remaining
      then AsConfigured
      else NotAsConfigured

renderReport :: Report -> [[Chunk]]
renderReport report =
  let problem :: Entry -> String -> [Chunk]
      problem entry what = [fore red (chunk (T.pack (concat [whereIs entry, ": ", what])))]
      detail :: Text -> [Chunk]
      detail text = [fore brightBlack (chunk (T.append "  " text))]
   in concat
        [ [[chunk (T.pack (unwords ["looking up", show (reportLookedUp report), if reportLookedUp report == 1 then "command" else "commands"]))]],
          concat
            [ problem entry "the router does not have this" : detail (asWritten entry) : map detail differences
            | (entry, differences) <- reportMissing report
            ],
          concat
            [ [ problem entry (concat ["the router has this, but not after what ", whereIs previous, " adds"]),
                detail (asWritten entry)
              ]
            | (entry, previous) <- reportOutOfOrder report
            ],
          concat
            [ [problem entry "the router has this, which the configuration does not add", detail (asWritten entry)]
            | entry <- reportUnasked report
            ],
          concat
            [ [ problem removal "the router still has what this removes",
                detail (asWritten removal),
                detail (T.pack (concat [whereIs entry, ": ", T.unpack (asWritten entry)]))
              ]
            | (removal, entry) <- reportLeftOver report
            ],
          if Map.null (reportNotLookedUp report)
            then []
            else
              [chunk "not looked up:"]
                : [detail (T.pack (unwords [show count, T.unpack what])) | (what, count) <- Map.toList (reportNotLookedUp report)],
          case reportOutcome report of
            AsConfigured -> [[fore green (chunk "the router has every command the configuration gave, in its order, and nothing more in its firewall")]]
            NotAsConfigured -> []
        ]

whereIs :: Entry -> String
whereIs entry = concat [fromSomeFile (entryFile entry), ":", show (entryLine entry)]

asWritten :: Entry -> Text
asWritten entry =
  if "/" `T.isPrefixOf` entryText entry
    then entryText entry
    else T.concat ["/", entrySection entry, " ", entryText entry]

-- | What the router reads as one line: a physical line, with the lines a
-- trailing backslash continues it onto, and with the rest of a block whose
-- braces it opens.
data Line = Line
  { -- | Of its first physical line, from one, as an editor counts them.
    lineNumber :: !Int,
    -- | Continuations joined, the lines of a block kept apart by newlines.
    lineBody :: !Text
  }
  deriving (Show, Eq)

-- | An unfinished last line is kept: it is still something the file says.
-- [check:ref ReadingOfAFile]
linesIn :: Text -> [Line]
linesIn =
  let go :: Maybe Line -> [(Int, Text)] -> [Line]
      go open = \case
        [] -> maybe [] pure open
        (number, raw) : rest ->
          let piece = T.strip raw
              skipped = T.null piece || "#" `T.isPrefixOf` piece
              joined = case open of
                Nothing
                  | skipped -> Nothing
                  | otherwise -> Just (Line {lineNumber = number, lineBody = piece})
                Just line -> case T.stripSuffix "\\" (lineBody line) of
                  -- RouterOS drops the indentation of a continued line, which
                  -- is why an export spells a space that starts one as @\\_@.
                  Just beginning -> Just line {lineBody = T.append beginning piece}
                  Nothing
                    | skipped -> Just line
                    | otherwise -> Just line {lineBody = T.intercalate "\n" [lineBody line, piece]}
           in case joined of
                Nothing -> go Nothing rest
                Just line
                  | "\\" `T.isSuffixOf` lineBody line || bracesOpenIn (lineBody line) > 0 ->
                      go (Just line) rest
                  | otherwise -> line : go Nothing rest
   in go Nothing . zip [1 ..] . T.lines

-- | Braces inside a string do not open a block.
bracesOpenIn :: Text -> Int
bracesOpenIn =
  let go :: Int -> Bool -> String -> Int
      go depth inString = \case
        [] -> depth
        '\\' : _ : rest -> go depth inString rest
        '"' : rest -> go depth (not inString) rest
        '{' : rest | not inString -> go (depth + 1) inString rest
        '}' : rest | not inString -> go (depth - 1) inString rest
        _ : rest -> go depth inString rest
   in go 0 False . T.unpack

-- | One command, as far as looking it up goes.
data Entry = Entry
  { entryFile :: !(SomeBase File),
    -- | Of the first line, from one, as an editor counts them.
    entryLine :: !Int,
    entrySection :: !Text,
    entryVerb :: !Text,
    -- | What picks out the thing a command is about: the name of an item
    -- written after the verb, as in @set telnet@, and what a selector such as
    -- @[ find default-name=ether1 ]@ asks of it.
    -- Nothing when it is picked out by what cannot be looked up: a number, an
    -- id, or a selector asking more than that values be equal.
    entrySelects :: !(Maybe [(Text, Text)]),
    entryArgs :: ![(Text, Text)],
    entryText :: !Text
  }
  deriving (Show, Eq)

-- | Only these say what something should be.
-- Removing it, and scripting, say what to do, which an export does not record.
comparable :: Entry -> Bool
comparable entry = entryVerb entry `elem` ["add", "set"]

-- | Scripting is kept whole, with its first word as its verb and nothing read
-- out of it: what it does depends on what it runs into, so there is nothing to
-- look up for it, only to count.
entriesIn :: SomeBase File -> Text -> [Entry]
entriesIn file =
  let go :: Text -> [Line] -> [Entry]
      go section = \case
        [] -> []
        line : rest ->
          let body = lineBody line
              entryOf :: Text -> [Word] -> Entry
              entryOf menu = \case
                Plain verb : after -> entryWith menu verb after
                words' -> entryWith menu "" (drop 1 words')
              entryWith :: Text -> Text -> [Word] -> Entry
              entryWith menu verb after =
                let selectorConditions = concat <$> mapM conditionsOf [selector | Selector selector <- after]
                    named = case after of
                      Plain word : _
                        | not ("=" `T.isInfixOf` word) ->
                            if namesAnItem word then Just [("name", word)] else Nothing
                      _ -> Just []
                 in Entry
                      { entryFile = file,
                        entryLine = lineNumber line,
                        entrySection = menu,
                        entryVerb = verb,
                        entrySelects = (++) <$> named <*> selectorConditions,
                        entryArgs = [argument | Plain word <- after, Just argument <- [argumentOf word]],
                        entryText = body
                      }
              script :: Entry
              script =
                Entry
                  { entryFile = file,
                    entryLine = lineNumber line,
                    entrySection = section,
                    entryVerb = T.takeWhile (not . isSpace) body,
                    entrySelects = Just [],
                    entryArgs = [],
                    entryText = body
                  }
           in if ":" `T.isPrefixOf` body || opensABlock body
                then script : go section rest
                else case T.stripPrefix "/" body of
                  Nothing -> entryOf section (wordsOf body) : go section rest
                  Just _ -> case slashLine body of
                    OnlyMenu menu -> go menu rest
                    CommandInMenu menu verbAt -> entryOf menu (wordsOf (T.drop verbAt body)) : go section rest
                    CommandAtRoot verbAt -> entryOf "" (wordsOf (T.drop verbAt body)) : go section rest
   in go "" . linesIn

argumentOf :: Text -> Maybe (Text, Text)
argumentOf word =
  let (key, rest) = T.breakOn "=" word
   in (,) key <$> T.stripPrefix "=" rest

-- | Whether a line has a block in braces, outside any string, such as the
-- @do={ ... }@ of a loop.
opensABlock :: Text -> Bool
opensABlock =
  let go :: Bool -> String -> Bool
      go inString = \case
        [] -> False
        '\\' : _ : rest -> go inString rest
        '"' : rest -> go (not inString) rest
        '{' : _ | not inString -> True
        _ : rest -> go inString rest
   in go False . T.unpack

-- | A number, or an id such as @*1@, picks out an item by where it is in a
-- listing, which an export does not say.
namesAnItem :: Text -> Bool
namesAnItem word = not ("*" `T.isPrefixOf` word) && not (T.all isDigit word)

data Word
  = Plain !Text
  | -- | What is between the square brackets that start a word, as it was
    -- written.
    Selector !Text
  deriving (Show, Eq)

-- | Words as RouterOS splits them: on spaces outside quotes and brackets, with
-- quotes and escapes taken away, so that @"a b"@, @a\\_b@ and @a\\ b@ are one
-- same word, and @caf\\C3\\A9@ is @café@.
-- Square brackets in the middle of a word are kept as they are.
wordsOf :: Text -> [Word]
wordsOf =
  let -- Bytes rather than characters, since an escape spells one byte of what
      -- may be a longer character, and kept backwards so that adding is cheap.
      plain :: [Word8] -> [Word] -> [Word]
      plain word rest = if null word then rest else Plain (decoded word) : rest
      decoded :: [Word8] -> Text
      decoded = TE.decodeUtf8With TEE.lenientDecode . BS.pack . reverse
      pushChar :: Char -> [Word8] -> [Word8]
      pushChar c word = reverse (BS.unpack (TE.encodeUtf8 (T.singleton c))) ++ word
      outside :: [Word8] -> Bool -> String -> [Word]
      outside word quoted = \case
        [] -> plain word []
        '\\' : high : low : rest
          | Just byte <- hexByte high low -> outside (byte : word) quoted rest
        '\\' : '_' : rest -> outside (pushChar ' ' word) quoted rest
        '\\' : escaped : rest -> outside (pushChar escaped word) quoted rest
        ['\\'] -> plain word []
        '"' : rest -> outside word (not quoted) rest
        '[' : rest
          | not quoted ->
              if null word
                then inside Nothing "" 1 False rest
                else inside (Just (pushChar '[' word)) "" 1 False rest
        c : rest
          | not quoted && (c == ' ' || c == '\t') -> plain word (outside [] False rest)
          | otherwise -> outside (pushChar c word) quoted rest
      -- Within brackets: a selector when they started a word, and otherwise
      -- part of the word they are in.
      inside :: Maybe [Word8] -> String -> Int -> Bool -> String -> [Word]
      inside word selector brackets quoted = \case
        [] -> maybe [] (`plain` []) word
        c : rest ->
          let brackets' = case c of
                '[' | not quoted -> brackets + 1
                ']' | not quoted -> brackets - 1
                _ -> brackets
              quoted' = if c == '"' then not quoted else quoted
              (taken, rest') = case (c, rest) of
                ('\\', escaped : more) -> ([c, escaped], more)
                _ -> ([c], rest)
           in case word of
                Nothing
                  | brackets' == 0 -> Selector (T.pack (reverse selector)) : outside [] quoted' rest'
                  | otherwise -> inside Nothing (reverse taken ++ selector) brackets' quoted' rest'
                Just bytes
                  | brackets' == 0 -> outside (foldr pushChar bytes (reverse taken)) quoted' rest'
                  | otherwise -> inside (Just (foldr pushChar bytes (reverse taken))) selector brackets' quoted' rest'
   in outside [] False . T.unpack

hexByte :: Char -> Char -> Maybe Word8
hexByte high low =
  if isHexDigit high && isHexDigit low
    then readMaybe ['0', 'x', high, low]
    else Nothing

-- | What a selector such as @[ find where default-name=ether1 ]@ asks of what
-- it picks, or Nothing for one that asks more than that values be equal.
conditionsOf :: Text -> Maybe [(Text, Text)]
conditionsOf selector =
  let condition :: Word -> Maybe (Text, Text)
      condition = \case
        Plain word -> do
          (key, value) <- argumentOf word
          if not (T.null key)
            && T.all (\c -> isAscii c && (isAlphaNum c || c == '-')) key
            && not (T.any (`elem` ['[', '$']) value)
            then Just (key, value)
            else Nothing
        Selector _ -> Nothing
      conditions = case wordsOf selector of
        Plain "find" : Plain "where" : rest -> Just rest
        Plain "find" : rest -> Just rest
        _ -> Nothing
   in conditions >>= mapM condition

-- | Keys whose values an export never shows, so that a configuration giving
-- one would always be reported missing.
-- RouterOS 7 leaves sensitive values out of an export unless asked to show
-- them, and the record is made without them so that it holds no secrets.
-- Where to put a new item, and what to copy it from, are how it was made
-- rather than what it is, and an export writes neither.
unshownKeys :: Set Text
unshownKeys =
  Set.fromList
    [ "authentication-password",
      "encryption-password",
      "ipsec-secret",
      "passphrase",
      "password",
      "preshared-key",
      "private-key",
      "secret",
      "wpa-pre-shared-key",
      "wpa2-pre-shared-key",
      "copy-from",
      "place-before"
    ]

shownArgs :: Entry -> [(Text, Text)]
shownArgs = filter (\(key, _) -> Set.notMember key unshownKeys) . entryArgs

-- | Every command the router has nothing to answer for, in the order the
-- files gave them.
-- An @add@ needs one of its own, since two the same are two things on the
-- router, while two @set@s may well be about the one thing.
missing :: [Entry] -> [Entry] -> [Entry]
missing asked has =
  let matched = Set.fromList (Map.elems (assignment asked has))
      unmatchedAdds = [add | (index, add) <- zip [0 ..] asked, entryVerb add == "add", Set.notMember index matched]
      unansweredSets =
        [ set
        | set <- asked,
          entryVerb set == "set",
          not (any (`answers` set) has)
        ]
   in inFileOrder (unmatchedAdds ++ unansweredSets)

-- | Each add the router has a match for that it does not have after what an
-- earlier add of the same menu matches, with that earlier add, where the order
-- is what the router goes by.
-- An add that comes too soon is one, rather than every one after it.
outOfOrder :: [Entry] -> [Entry] -> [(Entry, Entry)]
outOfOrder asked has =
  let matched = Set.fromList (Map.elems (assignment asked has))
      positionsOf :: Entry -> [Int]
      positionsOf add = [position | (position, candidate) <- zip [0 ..] has, entryVerb candidate == "add", answers candidate add]
      -- Taking the earliest place that will do leaves the most room for what
      -- comes after, so this only fails where no order of the router's would do.
      placed :: Maybe (Int, Entry) -> [Entry] -> [(Entry, Entry)]
      placed previous = \case
        [] -> []
        add : rest ->
          let after = maybe (const True) (\(position, _) -> (> position)) previous
           in case (filter after (positionsOf add), previous) of
                (position : _, _) -> placed (Just (position, add)) rest
                ([], Just (_, before)) -> (add, before) : placed previous rest
                ([], Nothing) -> placed previous rest
      inMenu :: Text -> [Entry]
      inMenu menu =
        [ add
        | (index, add) <- zip [0 ..] asked,
          entryVerb add == "add",
          entrySection add == menu,
          Set.member index matched
        ]
   in sortOn (inFileOrderOf . fst) (concatMap (placed Nothing . inMenu) (Set.toList orderedMenus))

-- | What the router has in a menu whose order it goes by, that no add of the
-- configuration accounts for.
-- Only there, because elsewhere RouterOS adds things of its own, and there a
-- rule nobody asked for is one that lets through what the rest keep out.
unasked :: [Entry] -> [Entry] -> [Entry]
unasked asked has =
  let owners = assignment asked has
   in [ candidate
      | (position, candidate) <- zip [0 ..] has,
        entryVerb candidate == "add",
        Set.member (entrySection candidate) orderedMenus,
        Map.notMember position owners
      ]

-- | Each remove, with what the router still has that it picks out.
-- What an add after the remove accounts for was put back on purpose.
leftOver :: [Entry] -> [Entry] -> [(Entry, Entry)]
leftOver asked has =
  let owners = assignment asked has
      putBackAfter :: Int -> Int -> Bool
      putBackAfter index position = maybe False (> index) (Map.lookup position owners)
   in [ (removal, candidate)
      | (index, removal) <- zip [0 ..] asked,
        entryVerb removal == "remove",
        Just conditions <- [entrySelects removal],
        (position, candidate) <- zip [0 ..] has,
        entrySection candidate == entrySection removal,
        picksOut candidate conditions,
        not (putBackAfter index position)
      ]

-- | How many of each kind of thing the configuration says were not looked
-- up, so that what was found says how much it covers.
notLookedUp :: [Entry] -> Map Text Int
notLookedUp =
  let reasons :: Entry -> [(Text, Int)]
      reasons entry = case entryVerb entry of
        verb
          | verb `elem` ["add", "set"] ->
              [ ("values an export does not show, such as passwords and place-before", unshown)
              | let unshown = length (entryArgs entry) - length (shownArgs entry),
                unshown > 0
              ]
                ++ [ ("adds and sets picked out by a number or by more than equal values, looked up by their values alone", 1)
                   | isNothing (entrySelects entry)
                   ]
        "remove" ->
          [ ("removes picked out by a number or by more than equal values", 1)
          | isNothing (entrySelects entry)
          ]
        verb -> [(T.unwords [verb, "commands"], 1)]
   in Map.fromListWith (+) . concatMap reasons

-- | The menus whose items RouterOS goes through in order, so that where an
-- item is matters as much as what it is.
orderedMenus :: Set Text
orderedMenus =
  Set.fromList
    [ T.unwords [ip, "firewall", table]
    | ip <- ["ip", "ipv6"],
      table <- ["filter", "nat", "mangle", "raw"]
    ]

inFileOrder :: [Entry] -> [Entry]
inFileOrder = sortOn inFileOrderOf

inFileOrderOf :: Entry -> (SomeBase File, Int)
inFileOrderOf entry = (entryFile entry, entryLine entry)

-- | Which add of the configuration each add the router has accounts for, by
-- where each is in its list.
-- An add needs one of its own, since two the same are two things on the
-- router, so this is a matching, as large as can be.
assignment :: [Entry] -> [Entry] -> Map Int Int
assignment asked has =
  matching
    ( Map.fromList
        [ (index, [position | (position, candidate) <- zip [0 ..] has, entryVerb candidate == "add", answers candidate add])
        | (index, add) <- zip [0 ..] asked,
          entryVerb add == "add"
        ]
    )

-- | Which of the asked each candidate goes to, as many as can at once, by
-- Kuhn's augmenting paths: taking the first that fits would let an add that
-- fits many take the only one another add fits.
matching :: Map Int [Int] -> Map Int Int
matching fitsOf =
  let augment :: Int -> Map Int Int -> Set Int -> (Bool, Map Int Int, Set Int)
      augment asked =
        let try :: [Int] -> Map Int Int -> Set Int -> (Bool, Map Int Int, Set Int)
            try candidates owner seen = case candidates of
              [] -> (False, owner, seen)
              candidate : others
                | Set.member candidate seen -> try others owner seen
                | otherwise ->
                    let seen' = Set.insert candidate seen
                        (free, owner', seen'') = case Map.lookup candidate owner of
                          Nothing -> (True, owner, seen')
                          Just other -> augment other owner seen'
                     in if free
                          then (True, Map.insert candidate asked owner', seen'')
                          else try others owner' seen''
         in try (Map.findWithDefault [] asked fitsOf)
   in foldl'
        (\owner asked -> let (_, owner', _) = augment asked owner Set.empty in owner')
        Map.empty
        (Map.keys fitsOf)

answers :: Entry -> Entry -> Bool
answers candidate asked =
  isTheOne candidate asked
    && all (uncurry (hasValue candidate)) (shownArgs asked)

-- | Whether a candidate is about what a command picks out.
-- A command picked out by what cannot be looked up is looked up by its values
-- alone.
isTheOne :: Entry -> Entry -> Bool
isTheOne candidate asked =
  sameKind candidate asked && picksOut candidate (fromMaybe [] (entrySelects asked))

picksOut :: Entry -> [(Text, Text)] -> Bool
picksOut candidate =
  all
    ( \(key, value) ->
        any (\(key', value') -> key' == key && sameValue value value') (fromMaybe [] (entrySelects candidate))
          || hasValue candidate key value
    )

-- | An export writes something a configuration added and then changed with a
-- @set@ as one @add@ with the change in it.
sameKind :: Entry -> Entry -> Bool
sameKind candidate asked =
  entrySection candidate == entrySection asked
    && ( entryVerb candidate == entryVerb asked
           || (entryVerb asked == "set" && entryVerb candidate == "add")
       )

hasValue :: Entry -> Text -> Text -> Bool
hasValue candidate key value = maybe False (sameValue value) (lookup key (entryArgs candidate))

-- | Only what a router has been seen to write differently from how it was
-- told, or writes in a form of its own: a MAC address in capitals, an address
-- in its shortest form, and with the prefix length it chose when it was given
-- none, a duration in other units, and a boolean as yes or no.
sameValue :: Text -> Text -> Bool
sameValue asked recorded =
  let both :: (Eq a) => (Text -> Maybe a) -> Bool
      both parse = isJust (parse asked) && parse asked == parse recorded
   in asked == recorded
        || (isMacAddress asked && T.toLower asked == T.toLower recorded)
        || sameAddress asked recorded
        || both durationOf
        || both booleanOf

isMacAddress :: Text -> Bool
isMacAddress value =
  let pairs = T.splitOn ":" value
   in length pairs == 6 && all (\pair -> T.length pair == 2 && T.all isHexDigit pair) pairs

sameAddress :: Text -> Text -> Bool
sameAddress asked recorded = case (addressOf asked, addressOf recorded) of
  (Just (askedAddress, askedLength), Just (recordedAddress, recordedLength)) ->
    askedAddress == recordedAddress
      && (askedLength == recordedLength || (isNothing askedLength && isJust recordedLength))
  _ -> False

-- | An address, and its prefix length if it has one.
addressOf :: Text -> Maybe (IP, Maybe Integer)
addressOf value =
  let (address, slashLength) = T.breakOn "/" value
   in case T.stripPrefix "/" slashLength of
        Nothing -> (\ip -> (ip, Nothing)) <$> readMaybe (T.unpack address)
        Just prefixLength -> do
          ip <- readMaybe (T.unpack address)
          number <- naturalOf prefixLength
          if number <= 255 then Just (ip, Just number) else Nothing

-- | In milliseconds.
-- RouterOS takes a duration in units, such as @1h30m@ or @500ms@, and writes
-- what is under a day as a clock: @1d02:00:00@, @00:10:00@.
durationOf :: Text -> Maybe Integer
durationOf text =
  let units :: [(Text, Integer)]
      units =
        [ ("ms", 1),
          ("w", 7 * 24 * 3600 * 1000),
          ("d", 24 * 3600 * 1000),
          ("h", 3600 * 1000),
          ("m", 60 * 1000),
          ("s", 1000)
        ]
      go :: Integer -> Text -> Maybe Integer
      go total rest
        | T.null rest = Just total
        | otherwise = do
            let (digits, after) = T.span isDigit rest
            count <- naturalOf digits
            if ":" `T.isPrefixOf` after
              then case mapM naturalOf (T.splitOn ":" rest) of
                Just [hours, minutes, seconds] -> Just (total + ((hours * 60 + minutes) * 60 + seconds) * 1000)
                _ -> Nothing
              else do
                (unit, size) <- case filter (\(unit, _) -> unit `T.isPrefixOf` after) units of
                  found : _ -> Just found
                  [] -> Nothing
                go (total + count * size) (T.drop (T.length unit) after)
   in if T.null text then Nothing else go 0 text

naturalOf :: Text -> Maybe Integer
naturalOf digits =
  if not (T.null digits) && T.all isDigit digits
    then readMaybe (T.unpack digits)
    else Nothing

booleanOf :: Text -> Maybe Bool
booleanOf = \case
  "yes" -> Just True
  "true" -> Just True
  "no" -> Just False
  "false" -> Just False
  _ -> Nothing

-- | What the most alike of what the router has says differently, which is
-- usually what to look at.
closestDifferences :: Entry -> [Entry] -> [Text]
closestDifferences asked has =
  let alike :: Entry -> Int
      alike candidate = length (filter (uncurry (hasValue candidate)) (shownArgs asked))
      theOnes = filter (`isTheOne` asked) has
   in if not (any (`sameKind` asked) has)
        then
          [ T.pack
              ( concat
                  [ "The router has no ",
                    if entryVerb asked == "set" then "add or set" else T.unpack (entryVerb asked),
                    " in /",
                    T.unpack (entrySection asked),
                    " at all."
                  ]
              )
          ]
        else case sortOn (negate . alike) theOnes of
          [] ->
            [ T.pack
                ( concat
                    [ "Nothing the router has in /",
                      T.unpack (entrySection asked),
                      " has ",
                      unwords [concat [T.unpack key, "=", T.unpack value] | (key, value) <- fromMaybe [] (entrySelects asked)],
                      "."
                    ]
                )
            ]
          closest : _ ->
            mapMaybe
              ( \(key, value) -> case lookup key (entryArgs closest) of
                  Nothing -> Just (T.pack (concat ["The closest one on the router has no ", T.unpack key, "."]))
                  Just recorded
                    | sameValue value recorded -> Nothing
                    | otherwise ->
                        Just
                          ( T.pack
                              ( concat
                                  [ "The closest one on the router has ",
                                    T.unpack key,
                                    "=",
                                    T.unpack recorded,
                                    ", not ",
                                    T.unpack value,
                                    "."
                                  ]
                              )
                          )
              )
              (shownArgs asked)
