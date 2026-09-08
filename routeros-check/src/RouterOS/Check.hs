{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Check a RouterOS script, since applying it is how you would otherwise find
-- out.
module RouterOS.Check
  ( Checkable (..),
    Host (..),
    checkScript,
    splitAtWayBackIn,
  )
where

import Control.Monad (when)
import Data.Aeson
import Data.Bits (complement, shiftL, shiftR, (.&.))
import Data.Char (isDigit, isHexDigit)
import Data.Foldable (sequenceA_, traverse_)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import Path
import RouterOS.Check.Chassis
import RouterOS.Check.Command
import RouterOS.Check.Location
import RouterOS.Check.Problem
import RouterOS.Check.Validation
import RouterOS.Check.Vocabulary
import Text.Read (readMaybe)

data Host = Host
  { hostName :: !Text,
    hostAddress :: !(Maybe Text),
    hostMac :: !Text,
    -- | 'Nothing' and @Just []@ differ: only a claim can be contradicted.
    hostForwards :: !(Maybe [Forward])
  }

-- | As a rule writes it, so comparing is comparing text.
data Forward = Forward
  { forwardProtocol :: !Text,
    forwardPort :: !Text
  }
  deriving (Eq)

instance FromJSON Host where
  parseJSON = withObject "Host" $ \o ->
    Host
      <$> o .: "name"
      <*> o .:? "address"
      <*> o .: "mac"
      <*> o .:? "forwards"

instance FromJSON Forward where
  parseJSON = withObject "Forward" $ \o ->
    Forward <$> o .: "protocol" <*> o .: "port"

-- | Absent is not empty: the checks that need it do not run, which is not them
-- passing.
data Checkable = Checkable
  { checkableFile :: !(SomeBase File),
    checkableScript :: !Text,
    checkableHosts :: ![Host],
    checkableChassis :: !(Maybe Chassis),
    checkableVocabulary :: !(Maybe Vocabulary)
  }

-- | No severities: a warning nobody acts on is how a check stops meaning
-- anything.
checkScript :: Checkable -> Validation Problem ()
checkScript Checkable {..} =
  let commands = parseScript checkableFile checkableScript
   in sequenceA_
        [ mixedLineEndings checkableScript,
          notRedeployableBeforeFallible commands,
          traverse_ malformedCommand commands,
          duplicateLeaseAddresses commands,
          duplicateLeaseMacs commands,
          malformedLeases commands,
          duplicateNatRules commands,
          useBeforeDefinition commands,
          duplicateBridgePorts commands,
          leasesCollidingWithRouter commands,
          natToUnleasedAddress commands,
          hostsWithoutLeases commands checkableHosts,
          hostsLeasedElsewhere commands checkableHosts,
          hostForwardsMissing commands checkableHosts,
          hostForwardsUndeclared commands checkableHosts,
          untriedWithoutReason commands,
          unseenByTheRouter checkableVocabulary commands,
          unknownInterfaces checkableChassis commands,
          unknownSerialPorts checkableChassis commands,
          subnetRouterAnycast commands,
          leasesForNoSuchServer commands,
          leasesOutsideTheNetwork commands
        ]

unseenByTheRouter :: Maybe Vocabulary -> [Command] -> Validation Problem ()
unseenByTheRouter Nothing _ = pure ()
unseenByTheRouter (Just vocabulary) commands =
  sequenceA_
    [ case commandUntried command of
        Nothing -> traverse_ validationFailure unseen
        Just _ ->
          when (null unseen) $
            validationFailure (UntriedWithNothingToExcuse (commandSpan command))
    | command <- commands,
      wellFormed command,
      let unseen = unseenIn vocabulary command
    ]

unseenIn :: Vocabulary -> Command -> [Problem]
unseenIn vocabulary command
  | not (knownMenu vocabulary section) = [UnseenMenu (commandSpan command) section]
  | otherwise = case knownParameters vocabulary section verb of
      Nothing -> [UnseenCommand (commandSpan command) section verb]
      Just known ->
        [ UnseenParameter (commandSpan command) section verb parameter
        | parameter <- Map.keys (commandArgs command),
          not (Set.member parameter known)
        ]
  where
    section = commandSection command
    verb = locatedValue (commandVerb command)

untriedWithoutReason :: [Command] -> Validation Problem ()
untriedWithoutReason commands =
  sequenceA_
    [ validationFailure (UntriedWithoutReason (commandSpan command))
    | command <- commands,
      Just reason <- [commandUntried command],
      T.null reason
    ]

unknownInterfaces :: Maybe Chassis -> [Command] -> Validation Problem ()
unknownInterfaces Nothing _ = pure ()
unknownInterfaces (Just chassis) commands =
  sequenceA_
    [ validationFailure (UnknownInterface (Located (locatedLocation located) name))
    | command <- commands,
      key <- ["interface", "in-interface", "out-interface", "default-name"],
      Just located <- [Map.lookup key (commandArgs command)],
      let name = T.dropWhile (== '!') (locatedValue located),
      not (T.null name),
      -- Nothing a file creates answers to a default name.
      name `notElem` (if key == "default-name" then hardware else hardware <> made)
    ]
  where
    hardware = chassisInterfaces chassis
    made = map fst (definitions commands)

-- | @\/port@ has one entry per serial port, so a further index selects nothing.
unknownSerialPorts :: Maybe Chassis -> [Command] -> Validation Problem ()
unknownSerialPorts Nothing _ = pure ()
unknownSerialPorts (Just chassis) commands =
  sequenceA_
    [ validationFailure (UnknownSerialPort (commandSpan command) index (chassisSerialPorts chassis))
    | command <- commands,
      commandSection command == "port",
      locatedValue (commandVerb command) == "set",
      Just index <- [indexIn (commandRest command)],
      index >= chassisSerialPorts chassis
    ]
  where
    indexIn :: Text -> Maybe Int
    indexIn rest = readMaybe (T.unpack (T.takeWhile isDigit rest))

-- | An address from a pool with no host part is @::@, which every router on the
-- link must answer for, so claiming it fails duplicate address detection and
-- leaves the interface with no valid address. The command succeeds; the network
-- refuses the result.
subnetRouterAnycast :: [Command] -> Validation Problem ()
subnetRouterAnycast commands =
  sequenceA_
    [ validationFailure (SubnetRouterAnycast (commandSpan command))
    | command <- commands,
      commandSection command == "ipv6 address",
      locatedValue (commandVerb command) == "add",
      Map.member "from-pool" (commandArgs command),
      maybe True (hostless . locatedValue) (Map.lookup "address" (commandArgs command))
    ]
  where
    -- Every spelling of the all-zero host part.
    hostless address =
      let withoutPrefix = T.takeWhile (/= '/') address
       in T.all (`elem` (":0" :: String)) withoutPrefix
            && T.any (== ':') withoutPrefix

-- | Unlike an interface, a dhcp server is never hardware. These lines are in
-- the half paired with the reset, so one that will not take costs the whole.
leasesForNoSuchServer :: [Command] -> Validation Problem ()
leasesForNoSuchServer commands =
  sequenceA_
    [ validationFailure (LeaseForNoSuchServer located)
    | command <- leases commands,
      Just located <- [Map.lookup "server" (commandArgs command)],
      locatedValue located `notElem` servers
    ]
  where
    servers =
      [ locatedValue located
      | command <- adds commands,
        commandSection command == "ip dhcp-server",
        Just located <- [Map.lookup "name" (commandArgs command)]
      ]

leasesOutsideTheNetwork :: [Command] -> Validation Problem ()
leasesOutsideTheNetwork commands =
  sequenceA_
    [ validationFailure (LeaseOutsideTheNetwork located (map fst networks))
    | command <- leases commands,
      Just located <- [Map.lookup "address" (commandArgs command)],
      Just address <- [parseIpv4 (locatedValue located)],
      not (any (contains address . snd) networks)
    ]
  where
    networks =
      [ (locatedValue located, network)
      | command <- adds commands,
        commandSection command == "ip dhcp-server network",
        Just located <- [Map.lookup "address" (commandArgs command)],
        Just network <- [parseCidr (locatedValue located)]
      ]

mixedLineEndings :: Text -> Validation Problem ()
mixedLineEndings script =
  let allLines = T.lines script
      carriage = length (filter ("\r" `T.isSuffixOf`) allLines)
   in when (carriage /= 0 && carriage /= length allLines) $
        validationFailure (MixedLineEndings carriage (length allLines))

splitAtWayBackIn :: SomeBase File -> Text -> Maybe (Text, Text)
splitAtWayBackIn file script = do
  reachable <- wayBackIn (parseScript file script)
  pure (splitAfterLine (sourcePositionLine (sourceSpanBegin reachable)) script)

-- | Past the last required piece and the last static lease with it: a dhcp
-- server without its leases hands out pool addresses instead, which a machine
-- asking in that window keeps for far longer than a deployment takes.
wayBackIn :: [Command] -> Maybe SourceSpan
wayBackIn commands = do
  spans <- traverse snd (requiredPieces commands)
  pure (foldr later (NE.head spans) (NE.tail spans <> map commandSpan (leases commands)))
  where
    later here there =
      if sourcePositionLine (sourceSpanBegin here)
        >= sourcePositionLine (sourceSpanBegin there)
        then here
        else there

splitAfterLine :: Int -> Text -> (Text, Text)
splitAfterLine line script = T.splitAt (afterNewlines line 0) script
  where
    afterNewlines 0 at = at
    afterNewlines remaining at = case T.findIndex (== '\n') (T.drop at script) of
      Nothing -> T.length script
      Just here -> afterNewlines (remaining - 1) (at + here + 1)

-- | More than reachable: a router whose clients have no addresses has nothing
-- able to reach it.
requiredPieces :: [Command] -> NonEmpty (String, Maybe SourceSpan)
requiredPieces commands =
  ("creates a bridge", firstAdd "interface bridge")
    :| [ ("puts a port on a bridge", firstAdd "interface bridge port"),
         ("gives the router an address", firstAdd "ip address"),
         ("makes an address pool", firstAdd "ip pool"),
         ("runs a dhcp server", firstAdd "ip dhcp-server"),
         ("gives that server a network", firstAdd "ip dhcp-server network")
       ]
  where
    firstAdd :: Text -> Maybe SourceSpan
    firstAdd section =
      listToMaybe
        [ commandSpan command
        | command <- commands,
          commandSection command == section,
          locatedValue (commandVerb command) == "add"
        ]

-- | A @[ find ]@ matching nothing stops the import where it stands, so these
-- belong after the way back in.
notRedeployableBeforeFallible :: [Command] -> Validation Problem ()
notRedeployableBeforeFallible commands =
  case wayBackIn commands of
    Nothing ->
      sequenceA_
        [ validationFailure (NotRedeployable what)
        | (what, Nothing) <- NE.toList (requiredPieces commands)
        ]
    Just redeployable ->
      sequenceA_
        [ validationFailure (FallibleBeforeRedeployable (commandSpan command) redeployable)
        | command <- commands,
          commandLine command < sourcePositionLine (sourceSpanBegin redeployable),
          selectsSomething command
        ]
  where
    selectsSomething command =
      locatedValue (commandVerb command) == "set"
        && case T.uncons (commandRest command) of
          Just ('[', _) -> True
          Just (c, _) -> isDigit c
          Nothing -> False

knownVerbs :: [Text]
knownVerbs = ["add", "set", "remove"]

wellFormed :: Command -> Bool
wellFormed command =
  not (T.null (commandSection command))
    && locatedValue (commandVerb command) `elem` knownVerbs

malformedCommand :: Command -> Validation Problem ()
malformedCommand command
  | T.null (commandSection command) =
      validationFailure (CommandOutsideSection (commandSpan command))
  | locatedValue (commandVerb command) `notElem` knownVerbs =
      validationFailure (UnknownVerb (commandVerb command))
  | otherwise = pure ()

leases :: [Command] -> [Command]
leases = filter (\c -> commandSection c == "ip dhcp-server lease" && locatedValue (commandVerb c) == "add")

natRules :: [Command] -> [Command]
natRules = filter (\c -> commandSection c == "ip firewall nat" && locatedValue (commandVerb c) == "add")

duplicateLeaseAddresses :: [Command] -> Validation Problem ()
duplicateLeaseAddresses commands =
  sequenceA_
    [ validationFailure (DuplicateLeaseAddress address firstSpan secondSpan)
    | (address, firstSpan, secondSpan) <- duplicatePairs (argOf "address" (leases commands))
    ]

duplicateLeaseMacs :: [Command] -> Validation Problem ()
duplicateLeaseMacs commands =
  sequenceA_
    [ validationFailure (DuplicateLeaseMac mac firstSpan secondSpan)
    | (mac, firstSpan, secondSpan) <-
        duplicatePairs
          [(T.toLower mac, macSpan) | (mac, macSpan) <- argOf "mac-address" (leases commands)]
    ]

malformedLeases :: [Command] -> Validation Problem ()
malformedLeases commands = traverse_ check (leases commands)
  where
    check command =
      let args = commandArgs command
       in sequenceA_
            [ if Map.member "address" args
                then pure ()
                else validationFailure (LeaseWithoutAddress (commandSpan command)),
              if Map.member "mac-address" args
                then pure ()
                else validationFailure (LeaseWithoutMac (commandSpan command)),
              sequenceA_
                [ validationFailure (MalformedLeaseAddress located)
                | Just located <- [Map.lookup "address" args],
                  not (looksLikeIpv4 (locatedValue located))
                ],
              sequenceA_
                [ validationFailure (MalformedLeaseMac located)
                | Just located <- [Map.lookup "mac-address" args],
                  not (looksLikeMac (locatedValue located))
                ]
            ]

-- | Keyed on everything a packet is matched against: two rules for one port are
-- normal when they differ elsewhere.
duplicateNatRules :: [Command] -> Validation Problem ()
duplicateNatRules commands =
  sequenceA_
    [ validationFailure (DuplicateNatRule key firstSpan secondSpan)
    | (key, firstSpan, secondSpan) <-
        duplicatePairs
          [ ( [ maybe "" locatedValue (Map.lookup field (commandArgs command))
              | field <- ["chain", "protocol", "dst-port", "dst-address", "in-interface", "to-addresses", "to-ports"]
              ],
              commandSpan command
            )
          | command <- natRules commands,
            fmap locatedValue (Map.lookup "action" (commandArgs command)) == Just "dst-nat"
          ]
    ]

-- | The import runs top to bottom, so this stops it where it stands.
useBeforeDefinition :: [Command] -> Validation Problem ()
useBeforeDefinition commands =
  sequenceA_
    [ validationFailure (UseBeforeDefinition located definitionSpan)
    | command <- commands,
      key <- referenceKeys,
      Just located <- [Map.lookup key (commandArgs command)],
      Just definitionSpan <- [lookup (locatedValue located) (definitions commands)],
      commandLine command < sourcePositionLine (sourceSpanBegin definitionSpan)
    ]

definitions :: [Command] -> [(Text, SourceSpan)]
definitions commands =
  [ (locatedValue located, locatedLocation located)
  | command <- commands,
    locatedValue (commandVerb command) == "add",
    Just located <- [Map.lookup "name" (commandArgs command)]
  ]

referenceKeys :: [Text]
referenceKeys =
  ["interface", "bridge", "server", "address-pool", "pool-name", "in-interface", "out-interface"]

duplicateBridgePorts :: [Command] -> Validation Problem ()
duplicateBridgePorts commands =
  sequenceA_
    [ validationFailure (DuplicateBridgePort interface firstSpan secondSpan)
    | (interface, firstSpan, secondSpan) <-
        duplicatePairs
          (argOf "interface" (filter ((== "interface bridge port") . commandSection) (adds commands)))
    ]

leasesCollidingWithRouter :: [Command] -> Validation Problem ()
leasesCollidingWithRouter commands =
  sequenceA_
    [ validationFailure (LeaseCollidesWithRouter located routerSpan)
    | command <- leases commands,
      Just located <- [Map.lookup "address" (commandArgs command)],
      Just routerSpan <- [lookup (locatedValue located) routerAddresses]
    ]
  where
    routerAddresses =
      [ (T.takeWhile (/= '/') (locatedValue located), locatedLocation located)
      | command <- adds commands,
        commandSection command == "ip address",
        Just located <- [Map.lookup "address" (commandArgs command)]
      ]

natToUnleasedAddress :: [Command] -> Validation Problem ()
natToUnleasedAddress commands =
  sequenceA_
    [ validationFailure (NatToUnleasedAddress located)
    | command <- natRules commands,
      fmap locatedValue (Map.lookup "action" (commandArgs command)) == Just "dst-nat",
      Just located <- [Map.lookup "to-addresses" (commandArgs command)],
      locatedValue located `notElem` leasedAddresses
    ]
  where
    leasedAddresses = map fst (argOf "address" (leases commands))

-- | Without the interface, a machine with two of them gets whichever address
-- the router felt like.
hostsWithoutLeases :: [Command] -> [Host] -> Validation Problem ()
hostsWithoutLeases commands hosts = traverse_ check (hostsServedBy commands hosts)
  where
    leasedAddresses = map fst (argOf "address" (leases commands))
    leasedMacs = map (T.toLower . fst) (argOf "mac-address" (leases commands))

    check host = case hostAddress host of
      Nothing -> pure ()
      Just address ->
        sequenceA_
          [ if address `elem` leasedAddresses
              then pure ()
              else validationFailure (HostAddressNotLeased (hostName host) address),
            if T.toLower (hostMac host) `elem` leasedMacs
              then pure ()
              else validationFailure (HostInterfaceNotLeased (hostName host) (hostMac host))
          ]

hostsLeasedElsewhere :: [Command] -> [Host] -> Validation Problem ()
hostsLeasedElsewhere commands hosts = traverse_ check (hostsServedBy commands hosts)
  where
    addressOfMac =
      Map.fromList
        [ (T.toLower (locatedValue mac), address)
        | command <- leases commands,
          Just mac <- [Map.lookup "mac-address" (commandArgs command)],
          Just address <- [Map.lookup "address" (commandArgs command)]
        ]

    check host = case (hostAddress host, Map.lookup (T.toLower (hostMac host)) addressOfMac) of
      (Just declared, Just leased)
        | declared /= locatedValue leased ->
            validationFailure (HostLeasedElsewhere (hostName host) declared leased)
      _ -> pure ()

hostForwardsMissing :: [Command] -> [Host] -> Validation Problem ()
hostForwardsMissing commands hosts =
  sequenceA_
    [ validationFailure (HostForwardMissing (hostName host) (forwardProtocol forward) (forwardPort forward))
    | host <- hostsServedBy commands hosts,
      Just address <- [hostAddress host],
      let forwarded = forwardsTo commands address,
      forward <- fromMaybe [] (hostForwards host),
      forward `notElem` forwarded
    ]

hostForwardsUndeclared :: [Command] -> [Host] -> Validation Problem ()
hostForwardsUndeclared commands hosts =
  sequenceA_
    [ validationFailure (HostForwardUndeclared (hostName host) (forwardProtocol forward) (Located (commandSpan command) (forwardPort forward)))
    | host <- hostsServedBy commands hosts,
      Just address <- [hostAddress host],
      Just declared <- [hostForwards host],
      command <- dstNatRules commands,
      Just target <- [Map.lookup "to-addresses" (commandArgs command)],
      locatedValue target == address,
      let forward = forwardOf command,
      forward `notElem` declared
    ]

forwardsTo :: [Command] -> Text -> [Forward]
forwardsTo commands address =
  [ forwardOf command
  | command <- dstNatRules commands,
    Just target <- [Map.lookup "to-addresses" (commandArgs command)],
    locatedValue target == address
  ]

-- | A rule naming neither forwards everything, hence @any@ and not skipped.
forwardOf :: Command -> Forward
forwardOf command =
  Forward (argOr "protocol") (argOr "dst-port")
  where
    argOr key =
      maybe "any" locatedValue (Map.lookup key (commandArgs command))

dstNatRules :: [Command] -> [Command]
dstNatRules commands =
  [ command
  | command <- natRules commands,
    fmap locatedValue (Map.lookup "action" (commandArgs command)) == Just "dst-nat"
  ]

hostsServedBy :: [Command] -> [Host] -> [Host]
hostsServedBy commands = filter served
  where
    networks =
      mapMaybe
        parseCidr
        [ locatedValue located
        | command <- adds commands,
          commandSection command == "ip dhcp-server network",
          Just located <- [Map.lookup "address" (commandArgs command)]
        ]

    served host = case hostAddress host >>= parseIpv4 of
      Nothing -> False
      Just address -> any (contains address) networks

contains :: Word32 -> (Word32, Int) -> Bool
contains address (network, prefix) =
  let mask = if prefix == 0 then 0 else complement (shiftR (complement 0 :: Word32) prefix)
   in (address .&. mask) == (network .&. mask)

adds :: [Command] -> [Command]
adds = filter ((== "add") . locatedValue . commandVerb)

argOf :: Text -> [Command] -> [(Text, SourceSpan)]
argOf key commands =
  [ (locatedValue located, locatedLocation located)
  | command <- commands,
    Just located <- [Map.lookup key (commandArgs command)]
  ]

duplicatePairs :: (Ord k) => [(k, SourceSpan)] -> [(k, SourceSpan, SourceSpan)]
duplicatePairs =
  mapMaybe pairOf
    . NE.groupBy (\a b -> fst a == fst b)
    . sortOn fst
  where
    pairOf group = case NE.toList group of
      (key, firstSpan) : (_, secondSpan) : _ -> Just (key, firstSpan, secondSpan)
      _ -> Nothing

looksLikeIpv4 :: Text -> Bool
looksLikeIpv4 text = case T.splitOn "." text of
  [a, b, c, d] -> all octet [a, b, c, d]
  _ -> False
  where
    octet piece = case readMaybe (T.unpack piece) :: Maybe Int of
      Nothing -> False
      Just value -> T.all isDigit piece && value < 256

looksLikeMac :: Text -> Bool
looksLikeMac text = case T.splitOn ":" text of
  pieces@[_, _, _, _, _, _] -> all pair pieces
  _ -> False
  where
    pair piece = T.length piece == 2 && T.all isHexDigit piece

parseCidr :: Text -> Maybe (Word32, Int)
parseCidr text = case T.splitOn "/" text of
  [address, prefix] -> (,) <$> parseIpv4 address <*> readMaybe (T.unpack prefix)
  [address] -> (,) <$> parseIpv4 address <*> Just 32
  _ -> Nothing

parseIpv4 :: Text -> Maybe Word32
parseIpv4 text = case T.splitOn "." text of
  [a, b, c, d] -> do
    octets <- traverse octet [a, b, c, d]
    pure (foldl (\acc o -> shiftL acc 8 + o) 0 octets)
  _ -> Nothing
  where
    octet :: Text -> Maybe Word32
    octet piece = do
      value <- readMaybe (T.unpack piece)
      if T.all isDigit piece && value < 256 then Just value else Nothing
