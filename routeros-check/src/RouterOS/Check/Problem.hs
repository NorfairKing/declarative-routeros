{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Everything this knows how to find, and how each one explains itself.
module RouterOS.Check.Problem
  ( Problem (..),
    ProblemCode (..),
    problemCode,
    problemCodeText,
    allProblemCodes,
  )
where

import Data.Char (isAsciiUpper)
import Data.List (intercalate, stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Error.Diagnose
import RouterOS.Check.Location
import RouterOS.Check.Validation (ToReport (..))

data Problem
  = MixedLineEndings !Int !Int
  | NotRedeployable !String
  | FallibleBeforeRedeployable !SourceSpan !SourceSpan
  | CommandOutsideSection !SourceSpan
  | UnknownVerb !(Located Text)
  | DuplicateLeaseAddress !Text !SourceSpan !SourceSpan
  | DuplicateLeaseMac !Text !SourceSpan !SourceSpan
  | LeaseWithoutAddress !SourceSpan
  | LeaseWithoutMac !SourceSpan
  | MalformedLeaseAddress !(Located Text)
  | MalformedLeaseMac !(Located Text)
  | DuplicateNatRule ![Text] !SourceSpan !SourceSpan
  | UseBeforeDefinition !(Located Text) !SourceSpan
  | DuplicateBridgePort !Text !SourceSpan !SourceSpan
  | LeaseCollidesWithRouter !(Located Text) !SourceSpan
  | NatToUnleasedAddress !(Located Text)
  | HostAddressNotLeased !Text !Text
  | HostInterfaceNotLeased !Text !Text
  | HostLeasedElsewhere !Text !Text !(Located Text)
  | HostForwardMissing !Text !Text !Text
  | HostForwardUndeclared !Text !Text !(Located Text)
  | -- | Fatal at compile time, which means nothing at all is applied.
    UnseenMenu !SourceSpan !Text
  | UnseenCommand !SourceSpan !Text !Text
  | UnseenParameter !SourceSpan !Text !Text !Text
  | UntriedWithoutReason !SourceSpan
  | -- | How the next reader learns to stop believing them.
    UntriedWithNothingToExcuse !SourceSpan
  | UnknownInterface !(Located Text)
  | UnknownSerialPort !SourceSpan !Int !Int
  | SubnetRouterAnycast !SourceSpan
  | LeaseForNoSuchServer !(Located Text)
  | LeaseOutsideTheNetwork !(Located Text) ![Text]

-- | Separate from 'Problem' so they can be enumerated, which is what lets the
-- build insist on an example for each.
data ProblemCode
  = CodeMixedLineEndings
  | CodeNotRedeployable
  | CodeFallibleBeforeRedeployable
  | CodeCommandOutsideSection
  | CodeUnknownVerb
  | CodeDuplicateLeaseAddress
  | CodeDuplicateLeaseMac
  | CodeLeaseWithoutAddress
  | CodeLeaseWithoutMac
  | CodeMalformedLeaseAddress
  | CodeMalformedLeaseMac
  | CodeDuplicateNatRule
  | CodeUseBeforeDefinition
  | CodeDuplicateBridgePort
  | CodeLeaseCollidesWithRouter
  | CodeNatToUnleasedAddress
  | CodeHostAddressNotLeased
  | CodeHostInterfaceNotLeased
  | CodeHostLeasedElsewhere
  | CodeHostForwardMissing
  | CodeHostForwardUndeclared
  | CodeUnseenMenu
  | CodeUnseenCommand
  | CodeUnseenParameter
  | CodeUntriedWithoutReason
  | CodeUntriedWithNothingToExcuse
  | CodeUnknownInterface
  | CodeUnknownSerialPort
  | CodeSubnetRouterAnycast
  | CodeLeaseForNoSuchServer
  | CodeLeaseOutsideTheNetwork
  deriving (Show, Eq, Ord, Enum, Bounded)

allProblemCodes :: [ProblemCode]
allProblemCodes = [minBound .. maxBound]

problemCode :: Problem -> ProblemCode
problemCode = \case
  MixedLineEndings {} -> CodeMixedLineEndings
  NotRedeployable {} -> CodeNotRedeployable
  FallibleBeforeRedeployable {} -> CodeFallibleBeforeRedeployable
  CommandOutsideSection {} -> CodeCommandOutsideSection
  UnknownVerb {} -> CodeUnknownVerb
  DuplicateLeaseAddress {} -> CodeDuplicateLeaseAddress
  DuplicateLeaseMac {} -> CodeDuplicateLeaseMac
  LeaseWithoutAddress {} -> CodeLeaseWithoutAddress
  LeaseWithoutMac {} -> CodeLeaseWithoutMac
  MalformedLeaseAddress {} -> CodeMalformedLeaseAddress
  MalformedLeaseMac {} -> CodeMalformedLeaseMac
  DuplicateNatRule {} -> CodeDuplicateNatRule
  UseBeforeDefinition {} -> CodeUseBeforeDefinition
  DuplicateBridgePort {} -> CodeDuplicateBridgePort
  LeaseCollidesWithRouter {} -> CodeLeaseCollidesWithRouter
  NatToUnleasedAddress {} -> CodeNatToUnleasedAddress
  HostAddressNotLeased {} -> CodeHostAddressNotLeased
  HostInterfaceNotLeased {} -> CodeHostInterfaceNotLeased
  HostLeasedElsewhere {} -> CodeHostLeasedElsewhere
  HostForwardMissing {} -> CodeHostForwardMissing
  HostForwardUndeclared {} -> CodeHostForwardUndeclared
  UnseenMenu {} -> CodeUnseenMenu
  UnseenCommand {} -> CodeUnseenCommand
  UnseenParameter {} -> CodeUnseenParameter
  UntriedWithoutReason {} -> CodeUntriedWithoutReason
  UntriedWithNothingToExcuse {} -> CodeUntriedWithNothingToExcuse
  UnknownInterface {} -> CodeUnknownInterface
  UnknownSerialPort {} -> CodeUnknownSerialPort
  SubnetRouterAnycast {} -> CodeSubnetRouterAnycast
  LeaseForNoSuchServer {} -> CodeLeaseForNoSuchServer
  LeaseOutsideTheNetwork {} -> CodeLeaseOutsideTheNetwork

-- | @CodeDuplicateLeaseMac@ becomes @duplicate-lease-mac@.
problemCodeText :: ProblemCode -> String
problemCodeText code = hyphenate (fromMaybe shown (stripPrefix "Code" shown))
  where
    shown = show code
    hyphenate = intercalate "-" . map (map toLowerAscii) . splitCamel
    toLowerAscii c = if isAsciiUpper c then toEnum (fromEnum c + 32) else c
    splitCamel [] = []
    splitCamel (c : cs) =
      let (rest, more) = break isAsciiUpper cs
       in (c : rest) : splitCamel more

instance ToReport Problem where
  toReport problem = case problem of
    MixedLineEndings carriage total ->
      reportOf
        "Some lines end in a carriage return and some do not."
        []
        [ Note $
            unwords
              [ show carriage,
                "of",
                show total,
                "lines end in a carriage return. RouterOS does not mind either,",
                "but a file that is half one and half the other has been edited",
                "by something that did not know which it was, and the next thing",
                "to edit it will make a diff nobody can read."
              ]
        ]
    NotRedeployable what ->
      reportOf
        (concat ["Nothing here ", what, ", so a failed deployment could not be followed by another."])
        []
        [ Note
            "Applying this file resets the router and replays it. Being reachable is not enough: a machine with no address of its own cannot reach the router either, so the file has to bring up the bridge, its ports, the router's own address, an address pool, a dhcp server and that server's network."
        ]
    FallibleBeforeRedeployable command redeployable ->
      reportOf
        "This command can fail, and runs before there would be a way back in to fix it."
        [ (toDiagnosePosition command, This "this selects something that might not be there"),
          (toDiagnosePosition redeployable, Where "the router is only reachable again from here")
        ]
        [ Hint
            "Move it below that line. A router missing a piece of hardware then comes up working and missing a setting, rather than needing a serial cable."
        ]
    CommandOutsideSection command ->
      reportOf
        "This command is not under any section."
        [(toDiagnosePosition command, This "no section was opened above this")]
        [Hint "Open one with a line starting in a slash, such as /interface bridge."]
    UnknownVerb (Located verbSpan verb) ->
      reportOf
        (concat ["Unknown command ", show (T.unpack verb), "."])
        [(toDiagnosePosition verbSpan, This "expected add, set or remove")]
        []
    DuplicateLeaseAddress address firstSpan secondSpan ->
      reportOf
        (concat ["Two leases hand out ", T.unpack address, "."])
        [ (toDiagnosePosition firstSpan, Where "leased here"),
          (toDiagnosePosition secondSpan, This "and again here")
        ]
        []
    DuplicateLeaseMac mac firstSpan secondSpan ->
      reportOf
        (concat ["Two leases are for ", T.unpack mac, "."])
        [ (toDiagnosePosition firstSpan, Where "leased here"),
          (toDiagnosePosition secondSpan, This "and again here")
        ]
        [Note "Compared without regard to case, because these files mix both."]
    LeaseWithoutAddress command ->
      reportOf
        "This lease does not say which address to hand out."
        [(toDiagnosePosition command, This "no address= here")]
        []
    LeaseWithoutMac command ->
      reportOf
        "This lease does not say which interface to hand it to."
        [(toDiagnosePosition command, This "no mac-address= here")]
        []
    MalformedLeaseAddress (Located addressSpan address) ->
      reportOf
        (concat ["Malformed address ", show (T.unpack address), "."])
        [(toDiagnosePosition addressSpan, This "expected four numbers under 256, separated by dots")]
        []
    MalformedLeaseMac (Located macSpan mac) ->
      reportOf
        (concat ["Malformed mac-address ", show (T.unpack mac), "."])
        [(toDiagnosePosition macSpan, This "expected six pairs of hex digits, separated by colons")]
        []
    DuplicateNatRule key firstSpan secondSpan ->
      reportOf
        "Two dst-nat rules match on exactly the same thing, so the second can never fire."
        [ (toDiagnosePosition firstSpan, Where "this one matches first"),
          (toDiagnosePosition secondSpan, This "so this one never does")
        ]
        [ Note $
            concat ["Both match on: ", T.unpack (T.intercalate " " (filter (not . T.null) key))]
        ]
    UseBeforeDefinition (Located useSpan name) definitionSpan ->
      reportOf
        (concat ["This uses ", T.unpack name, " before the line that creates it."])
        [ (toDiagnosePosition useSpan, This "used here"),
          (toDiagnosePosition definitionSpan, Where "not created until here")
        ]
        [Note "The import runs top to bottom, so this fails while running and takes everything below it with it."]
    DuplicateBridgePort interface firstSpan secondSpan ->
      reportOf
        (concat [T.unpack interface, " is added to a bridge twice."])
        [ (toDiagnosePosition firstSpan, Where "added here"),
          (toDiagnosePosition secondSpan, This "and again here")
        ]
        [Note "The second one fails while running."]
    LeaseCollidesWithRouter (Located leaseSpan address) routerSpan ->
      reportOf
        (concat ["This leases ", T.unpack address, ", which the router holds itself."])
        [ (toDiagnosePosition leaseSpan, This "handed out to a machine"),
          (toDiagnosePosition routerSpan, Where "and held by the router")
        ]
        []
    NatToUnleasedAddress (Located targetSpan target) ->
      reportOf
        (concat ["This forwards to ", T.unpack target, ", which nothing here leases."])
        [(toDiagnosePosition targetSpan, This "no lease pins this address")]
        [Hint "Add a lease for it, or the rule works until the machine behind it is handed a different address."]
    HostAddressNotLeased name address ->
      reportOf
        (concat [T.unpack name, " is declared at ", T.unpack address, ", but nothing here leases that address."])
        []
        [Note "Declared outside this file, by whatever produced the hosts given on the command line."]
    HostInterfaceNotLeased name mac ->
      reportOf
        (concat [T.unpack name, " is declared as ", T.unpack mac, ", but nothing here leases that interface."])
        []
        [ Hint
            "Lease the interface as well as the address. Without that, a machine with two interfaces gets whichever address the router felt like handing out."
        ]
    HostLeasedElsewhere name declared (Located leaseSpan leased) ->
      reportOf
        ( concat
            [ T.unpack name,
              " is declared at ",
              T.unpack declared,
              ", but its declared interface is leased ",
              T.unpack leased,
              "."
            ]
        )
        [(toDiagnosePosition leaseSpan, This "leased here")]
        [Note "Legitimate for a machine with two interfaces, and worth saying out loud either way."]
    HostForwardMissing name protocol port ->
      reportOf
        ( concat
            [ T.unpack name,
              " expects ",
              T.unpack protocol,
              " ",
              T.unpack port,
              " forwarded to it, and nothing here forwards it."
            ]
        )
        []
        [ Hint
            "Either add the rule, or stop expecting it. A machine reached on a port nothing forwards is a machine nobody can reach that way, and finding that out takes until somebody tries."
        ]
    HostForwardUndeclared name protocol (Located ruleSpan port) ->
      reportOf
        ( concat
            [ "This forwards ",
              if protocol == "any" && port == "any"
                then "everything"
                else unwords [T.unpack protocol, T.unpack port],
              " to ",
              T.unpack name,
              ", which does not expect it."
            ]
        )
        [(toDiagnosePosition ruleSpan, This "forwarded here")]
        [ Hint
            "Either the rule is left over from something that has moved, or the machine has grown a service nothing has been told about. Both are worth knowing; a forward nobody meant is a hole nobody is watching."
        ]
    UnseenMenu commandSpan menu ->
      reportOf
        (concat ["No export of this router mentions /", T.unpack menu, "."])
        [(toDiagnosePosition commandSpan, This "this router may have no such menu")]
        [ Note
            "A menu RouterOS does not have is a compile error, and /import compiles the whole file before it runs any of it, so the router would come up with nothing at all applied.",
          Note
            "An export prints no menu that has nothing in it, so this says the router has never had anything here rather than that it could not.",
          Hint
            "If this is meant to be new, say so in a comment above it: [untried] and why. Setting it on the router by hand and downloading again is the other way, and the stronger one."
        ]
    UnseenCommand commandSpan menu verb ->
      reportOf
        (concat ["No export of this router has ", T.unpack verb, " under /", T.unpack menu, "."])
        [(toDiagnosePosition commandSpan, This "the menu is known, this command is not")]
        [ Note
            "An export only ever uses the command it needs to say what the router is set to, which for a menu of settings is set and for a menu of items is add. So this says the router has never been asked this, rather than that it would refuse.",
          Hint "Say [untried] and why in a comment above it if this is meant to be new."
        ]
    UnseenParameter commandSpan menu verb parameter ->
      reportOf
        ( concat
            [ "No export of this router names ",
              T.unpack parameter,
              " on ",
              T.unpack verb,
              " under /",
              T.unpack menu,
              "."
            ]
        )
        [(toDiagnosePosition commandSpan, This "this parameter may not exist here")]
        [ Note
            "A verbose export prints every parameter a command has, at its default, so a name missing from one is a name this RouterOS does not know rather than one it has no use for.",
          Hint "Say [untried] and why in a comment above it if this is meant to be new."
        ]
    UntriedWithoutReason commandSpan ->
      reportOf
        "This is marked [untried] without saying why."
        [(toDiagnosePosition commandSpan, This "excused by the comment above, for no stated reason")]
        [ Hint
            "Write what the router is being asked that it has never been asked before, and how you know it will take it. An annotation nobody has to justify is one nobody reads."
        ]
    UntriedWithNothingToExcuse commandSpan ->
      reportOf
        "This is marked [untried], and this router has already been seen to accept every word of it."
        [(toDiagnosePosition commandSpan, This "nothing here needs excusing")]
        [Note "Left behind by something that has since been downloaded, most likely. Delete the annotation."]
    UnknownInterface (Located nameSpan name) ->
      reportOf
        (concat [T.unpack name, " is not on this chassis, and nothing here creates it."])
        [(toDiagnosePosition nameSpan, This "no such interface")]
        [ Note
            "The chassis is what the router answered when asked for the default name of each of its ethernet interfaces.",
          Hint "A bridge or a vlan has to be created above the line that uses it; hardware cannot be created at all."
        ]
    UnknownSerialPort commandSpan index count ->
      reportOf
        ( if count == 0
            then
              concat
                ["This names serial port ", show index, ", and this chassis has none at all."]
            else
              concat
                [ "This names serial port ",
                  show index,
                  ". The last one on this chassis is ",
                  show (count - 1),
                  "."
                ]
        )
        [(toDiagnosePosition commandSpan, This "no /port has this index")]
        [Note "It fails while running, so everything below it is skipped and everything above it stays."]
    SubnetRouterAnycast commandSpan ->
      reportOf
        "This takes an address from a pool with no host part, which is the subnet-router anycast address."
        [(toDiagnosePosition commandSpan, This "an address= that is all zeroes, or none at all, which means the same")]
        [ Note
            "Every IPv6 router on a link has to answer for that address, so claiming it fails duplicate address detection and the interface ends up with no valid address at all. Nothing else stops working: the router keeps its own connectivity and only the clients lose theirs.",
          Note
            "A router that already holds the address never runs detection again, so a configuration doing this works until the first time it is applied to a router that has been reset.",
          Hint "Give it a host part: address=::1."
        ]
    LeaseForNoSuchServer (Located serverSpan server) ->
      reportOf
        (concat ["No dhcp server here is called ", T.unpack server, "."])
        [(toDiagnosePosition serverSpan, This "nothing creates this")]
        [ Note
            "A dhcp server is never hardware: an interface a file does not create may still be on the chassis, and a server a file does not create does not exist. These leases are in the half a reset is paired with, so one that will not take costs the whole of it.",
          Hint "Name one that /ip dhcp-server creates above this."
        ]
    LeaseOutsideTheNetwork (Located addressSpan address) networks ->
      reportOf
        (concat ["Nothing here hands out ", T.unpack address, "."])
        [(toDiagnosePosition addressSpan, This "not in any network a dhcp server serves")]
        [ Note $
            if null networks
              then "No /ip dhcp-server network says which addresses are handed out at all."
              else concat ["Handed out here: ", T.unpack (T.intercalate ", " networks), "."]
        ]
    where
      reportOf = Err (Just (problemCodeText (problemCode problem)))
