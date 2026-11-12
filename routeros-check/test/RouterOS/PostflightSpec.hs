{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module RouterOS.PostflightSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Path
import RouterOS.Postflight
import Test.QuickCheck
import Test.Syd
import Text.Colour (TerminalCapabilities (..), renderChunksText, unlinesChunks)
import Prelude hiding (Word)

spec :: Spec
spec = do
  describe "linesIn" $ do
    it "joins a wrapped line onto its first, without the indent of the next" $
      linesIn "/tool netwatch\r\nadd comment=adguard down-script=\"/ip fi\\\r\n    rewall nat\"\r\n"
        `shouldBe` [ Line {lineNumber = 1, lineBody = "/tool netwatch"},
                     Line {lineNumber = 2, lineBody = "add comment=adguard down-script=\"/ip firewall nat\""}
                   ]

    it "keeps a block whole, with its lines apart" $
      linesIn ":foreach i in={1;2} do={\n/ip address add address=10.0.0.$i/24\n}\n/system identity\n"
        `shouldBe` [ Line {lineNumber = 1, lineBody = ":foreach i in={1;2} do={\n/ip address add address=10.0.0.$i/24\n}"},
                     Line {lineNumber = 4, lineBody = "/system identity"}
                   ]

    it "leaves out comments and blank lines" $
      linesIn "# a comment\n\n/ip firewall nat\n"
        `shouldBe` [Line {lineNumber = 3, lineBody = "/ip firewall nat"}]

  describe "entriesIn" $ do
    it "reads a wrapped line as one command from its first line" $
      entriesIn
        (Rel [relfile|export-verbose.rsc|])
        "/tool netwatch\r\nadd comment=adguard down-script=\"/ip fi\\\r\n    rewall nat disable [find\\\r\n    \\_where comment=x]\"\r\n"
        `shouldBe` [ Entry
                       { entryFile = Rel [relfile|export-verbose.rsc|],
                         entryLine = 2,
                         entrySection = "tool netwatch",
                         entryVerb = "add",
                         entrySelects = Just [],
                         entryArgs =
                           [ ("comment", "adguard"),
                             ("down-script", "/ip firewall nat disable [find where comment=x]")
                           ],
                         entryText = "add comment=adguard down-script=\"/ip firewall nat disable [find\\_where comment=x]\""
                       }
                   ]

    it "gives each command its section and line" $
      entriesIn (Rel [relfile|configuration.rsc|]) "# a comment\n/ip firewall nat\n\nadd chain=srcnat action=masquerade\n"
        `shouldBe` [ Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 4,
                         entrySection = "ip firewall nat",
                         entryVerb = "add",
                         entrySelects = Just [],
                         entryArgs = [("chain", "srcnat"), ("action", "masquerade")],
                         entryText = "add chain=srcnat action=masquerade"
                       }
                   ]

    it "gives each command what it picks out, by name or by selector, and nothing it can look up for a number" $
      entriesIn
        (Rel [relfile|configuration.rsc|])
        "/ip service\nset telnet address=192.168.99.0/24\nset 0 port=23\n/interface ethernet\nset [ find default-name=ether1 ] mtu=1500\n"
        `shouldBe` [ Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 2,
                         entrySection = "ip service",
                         entryVerb = "set",
                         entrySelects = Just [("name", "telnet")],
                         entryArgs = [("address", "192.168.99.0/24")],
                         entryText = "set telnet address=192.168.99.0/24"
                       },
                     Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 3,
                         entrySection = "ip service",
                         entryVerb = "set",
                         entrySelects = Nothing,
                         entryArgs = [("port", "23")],
                         entryText = "set 0 port=23"
                       },
                     Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 5,
                         entrySection = "interface ethernet",
                         entryVerb = "set",
                         entrySelects = Just [("default-name", "ether1")],
                         entryArgs = [("mtu", "1500")],
                         entryText = "set [ find default-name=ether1 ] mtu=1500"
                       }
                   ]

    it "reads a command on the line of its menu, which leaves the menu alone" $
      entriesIn (Rel [relfile|configuration.rsc|]) "/ip firewall nat\n/interface ethernet set ether1 mtu=1500\nadd chain=srcnat\n"
        `shouldBe` [ Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 2,
                         entrySection = "interface ethernet",
                         entryVerb = "set",
                         entrySelects = Just [("name", "ether1")],
                         entryArgs = [("mtu", "1500")],
                         entryText = "/interface ethernet set ether1 mtu=1500"
                       },
                     Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 3,
                         entrySection = "ip firewall nat",
                         entryVerb = "add",
                         entrySelects = Just [],
                         entryArgs = [("chain", "srcnat")],
                         entryText = "add chain=srcnat"
                       }
                   ]

    it "keeps scripting whole, with nothing read out of it" $
      entriesIn (Rel [relfile|configuration.rsc|]) "/ip address\n:delay 1s\n:foreach i in={1;2} do={\n/ip address add address=10.0.0.$i/24\n}\n"
        `shouldBe` [ Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 2,
                         entrySection = "ip address",
                         entryVerb = ":delay",
                         entrySelects = Just [],
                         entryArgs = [],
                         entryText = ":delay 1s"
                       },
                     Entry
                       { entryFile = Rel [relfile|configuration.rsc|],
                         entryLine = 3,
                         entrySection = "ip address",
                         entryVerb = ":foreach",
                         entrySelects = Just [],
                         entryArgs = [],
                         entryText = ":foreach i in={1;2} do={\n/ip address add address=10.0.0.$i/24\n}"
                       }
                   ]

  describe "wordsOf" $ do
    it "takes away quotes and escapes, and keeps selectors as written" $
      wordsOf "set [ find default=yes ] comment=\"a b\" script=\"x [find where c=\\\"d\\\"]\\_e\" mtu=1500"
        `shouldBe` [ Plain "set",
                     Selector " find default=yes ",
                     Plain "comment=a b",
                     Plain "script=x [find where c=\"d\"] e",
                     Plain "mtu=1500"
                   ]

    it "keeps brackets in the middle of a word as part of it" $
      wordsOf "set interface=[/interface get [find comment=\"a b\"] name] mtu=1500"
        `shouldBe` [ Plain "set",
                     Plain "interface=[/interface get [find comment=\"a b\"] name]",
                     Plain "mtu=1500"
                   ]

    it "spells bytes in hex" $
      wordsOf "set comment=caf\\C3\\A9 name=\"a\\41\""
        `shouldBe` [Plain "set", Plain "comment=caf\233", Plain "name=aA"]

    it "splits words of letters on spaces" $
      forAll (listOf1 (T.pack <$> listOf1 (elements ['a' .. 'z']))) $ \plainWords ->
        wordsOf (T.unwords plainWords) `shouldBe` map Plain plainWords

  describe "conditionsOf" $ do
    it "is what a selector asks to be equal" $
      conditionsOf " find where default-name=ether1 comment=\"a b\" "
        `shouldBe` Just [("default-name", "ether1"), ("comment", "a b")]

    it "is Nothing for a selector that asks more than that" $
      map conditionsOf ["find comment~\"x\"", "find name!=x", "find name=a or name=b", "find name=$wanted"]
        `shouldBe` [Nothing, Nothing, Nothing, Nothing]

  describe "missing" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "is nothing for what a router has in itself" $
      forAll (listOf (T.pack <$> listOf1 (elements ['a' .. 'z']))) $ \names ->
        let entries = configuration (T.unlines ("/ip firewall filter" : [T.concat ["add chain=input comment=", name] | name <- names]))
         in missing entries entries `shouldBe` []

    it "is nothing for an export that spells every value its own way" $ do
      let asked = configuration "/ip dhcp-server lease\nadd address=192.168.88.10 mac-address=a0:36:9f:28:d7:7a comment=\"dec\"\n/ipv6 address\nadd address=::1 interface=lan\n"
      let has = export "/ip dhcp-server lease\nadd address=192.168.88.10 comment=dec disabled=no mac-address=A0:36:9F:28:D7:7A\n/ipv6 address\nadd address=::1/64 advertise=yes interface=lan\n"
      missing asked has `shouldBe` []

    it "has a value the router has otherwise" $ do
      let asked = configuration "/system identity\nset name=wanted\n"
      missing asked (export "/system identity\nset name=something-else\n") `shouldBe` asked

    it "needs two the same on the router for two adds the same" $ do
      let asked = configuration "/ip firewall filter\nadd chain=input action=accept\nadd chain=input action=accept\n"
      missing asked (export "/ip firewall filter\nadd action=accept chain=input disabled=no\n")
        `shouldBe` drop 1 asked

    it "leaves the one another add needs to it, when an add fits many" $
      missing
        (configuration "/ip firewall filter\nadd chain=input\nadd chain=input action=drop\n")
        (export "/ip firewall filter\nadd chain=input action=drop\nadd chain=input action=accept\n")
        `shouldBe` []

    it "lets two sets be about the same thing" $
      missing
        (configuration "/interface ethernet\nset [ find default-name=ether1 ] name=wan\nset [ find name=wan ] mtu=1500\n")
        (export "/interface ethernet\nset [ find default-name=ether1 ] mtu=1500 name=wan\n")
        `shouldBe` []

    it "does not look up what says what to do" $
      missing (configuration "/ip firewall filter\nremove [ find comment=old ]\n:delay 1s\n") [] `shouldBe` []

    it "finds a set on what was added in the add it changed" $
      missing
        (configuration "/ip firewall filter\nadd chain=input comment=x\nset [ find comment=x ] disabled=yes\n")
        (export "/ip firewall filter\nadd chain=input comment=x disabled=yes\n")
        `shouldBe` []

    it "only answers a set on a named item with that item" $ do
      let asked = configuration "/ip service\nset telnet address=192.168.99.0/24\nset ftp address=192.168.99.0/24\nset www address=192.168.99.0/24\nset ssh address=192.168.99.0/24\n"
      missing asked (export "/ip service\nset telnet address=\"\" port=23\nset ftp address=\"\"\nset www address=\"\"\nset ssh address=192.168.99.0/24\n")
        `shouldBe` take 3 asked

    it "only answers a set on a default name with that one" $ do
      let asked = configuration "/interface ethernet\nset [ find default-name=ether1 ] mtu=1500\n"
      missing asked (export "/interface ethernet\nset [ find default-name=ether1 ] mtu=1400 name=ether1\nset [ find default-name=ether2 ] mtu=1500 name=ether2\n")
        `shouldBe` asked

    it "does not look up a secret the export leaves out" $
      missing
        (configuration "/ppp secret\nadd name=a password=s service=pppoe\n")
        (export "/ppp secret\nadd name=a profile=default service=pppoe\n")
        `shouldBe` []

    it "does not look up where to put something" $
      missing
        (configuration "/ip firewall filter\nadd chain=input action=drop place-before=0\n")
        (export "/ip firewall filter\nadd action=drop chain=input\n")
        `shouldBe` []

  describe "outOfOrder" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "is nothing for firewall rules a router has in itself" $
      forAll (listOf (T.pack <$> listOf1 (elements ['a' .. 'c']))) $ \names ->
        let entries = configuration (T.unlines ("/ip firewall filter" : [T.concat ["add chain=input comment=", name] | name <- names]))
         in outOfOrder entries entries `shouldBe` []

    it "names a rule the router has before the one the configuration put first" $ do
      let asked = configuration "/ip firewall filter\nadd chain=input action=accept comment=a\nadd chain=input action=drop comment=b\n"
      outOfOrder asked (export "/ip firewall filter\nadd action=drop chain=input comment=b\nadd action=accept chain=input comment=a\n")
        `shouldBe` case asked of
          [first, second] -> [(second, first)]
          _ -> []

    it "names only the rule that came too soon, not every one after it" $ do
      let asked = configuration "/ip firewall nat\nadd chain=a\nadd chain=b\nadd chain=c\nadd chain=d\n"
      outOfOrder asked (export "/ip firewall nat\nadd chain=d\nadd chain=a\nadd chain=b\nadd chain=c\n")
        `shouldBe` case asked of
          [_, _, third, fourth] -> [(fourth, third)]
          _ -> []

    it "takes rules the same as each other in any order" $ do
      let asked = configuration "/ip firewall filter\nadd chain=input\nadd chain=input\n"
      outOfOrder asked (export "/ip firewall filter\nadd chain=input disabled=no\nadd chain=input disabled=no\n")
        `shouldBe` []

    it "does not mind the order where the router does not" $ do
      let asked = configuration "/ip address\nadd address=10.0.0.1/24 interface=a\nadd address=10.0.1.1/24 interface=b\n"
      outOfOrder asked (export "/ip address\nadd address=10.0.1.1/24 interface=b\nadd address=10.0.0.1/24 interface=a\n")
        `shouldBe` []

  describe "unasked" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "names a firewall rule the configuration does not add" $ do
      let has = export "/ip firewall nat\nadd action=redirect chain=dstnat dst-port=53 protocol=udp\nadd action=accept chain=dstnat dst-port=53 protocol=udp\n"
      unasked (configuration "/ip firewall nat\nadd chain=dstnat action=redirect protocol=udp dst-port=53\n") has
        `shouldBe` drop 1 has

    it "does not name what RouterOS adds of its own outside the firewall" $
      unasked (configuration "/ip address\nadd address=10.0.0.1/24 interface=a\n") (export "/ip address\nadd address=10.0.0.1/24 interface=a\nadd address=192.168.88.1/24 interface=b\n")
        `shouldBe` []

  describe "leftOver" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "names what the router still has that a remove picks out" $ do
      let asked = configuration "/ip firewall filter\nremove [ find comment=old ]\n"
      let has = export "/ip firewall filter\nadd chain=input comment=old\nadd chain=input comment=new\n"
      leftOver asked has `shouldBe` zip asked (take 1 has)

    it "does not name what an add after the remove puts back" $
      leftOver
        (configuration "/ip firewall filter\nremove [ find comment=kept ]\nadd chain=input comment=kept\n")
        (export "/ip firewall filter\nadd chain=input comment=kept\n")
        `shouldBe` []

    it "does not look at a remove by number" $
      leftOver (configuration "/ip firewall filter\nremove 0\n") (export "/ip firewall filter\nadd chain=input\n")
        `shouldBe` []

  describe "notLookedUp" $
    it "counts what it could not look up" $
      notLookedUp
        ( entriesIn
            (Rel [relfile|configuration.rsc|])
            ":delay 1s\n:delay 2s\n/ppp secret\nadd name=a password=s\n/ip firewall filter\nremove 0\nremove [ find comment=x ]\nset 0 disabled=yes\ndisable 1\n"
        )
        `shouldBe` Map.fromList
          [ (":delay commands", 2),
            ("disable commands", 1),
            ("values an export does not show, such as passwords and place-before", 1),
            ("adds and sets picked out by a number or by more than equal values, looked up by their values alone", 1),
            ("removes picked out by a number or by more than equal values", 1)
          ]

  describe "sameValue" $ do
    it "is the same for anything and itself" $
      property $
        \value -> sameValue (T.pack value) (T.pack value)

    it "takes MAC addresses in any case, and nothing else" $
      map (uncurry sameValue) [("aa:bb:cc:dd:ee:ff", "AA:BB:CC:DD:EE:FF"), ("wan", "WAN")]
        `shouldBe` [True, False]

    it "takes an address without a length as the one with the length the router chose" $
      map (uncurry sameValue) [("::1", "::1/64"), ("192.168.88.1", "192.168.88.1/32"), ("192.168.88.1", "192.168.88.10/32"), ("192.168.88.1/24", "192.168.88.1/32")]
        `shouldBe` [True, True, False, False]

    it "takes addresses however they are spelled" $
      map (uncurry sameValue) [("2001:DB8:0::1", "2001:db8::1"), ("2001:DB8::/32", "2001:db8::/32"), ("2001:db8::/32", "2001:db8::/48"), ("2001:db8::1", "2001:db8::2")]
        `shouldBe` [True, True, False, False]

    it "gives only an address the length the router chose" $
      sameValue "lan" "lan/24" `shouldBe` False

    it "takes durations however they are spelled" $
      map (uncurry sameValue) [("10m", "00:10:00"), ("600s", "10m"), ("1d2h", "1d02:00:00"), ("1w", "7d"), ("1500ms", "1s500ms"), ("10m", "00:10:01")]
        `shouldBe` [True, True, True, True, True, False]

    it "takes true and false as yes and no" $
      map (uncurry sameValue) [("true", "yes"), ("no", "false"), ("true", "no")]
        `shouldBe` [True, True, False]

  describe "closestDifferences" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "says what the closest has instead" $
      concatMap (`closestDifferences` export "/system identity\nset name=other\n") (configuration "/system identity\nset name=wanted\n")
        `shouldBe` ["The closest one on the router has name=other, not wanted."]

    it "says when nothing is the one picked out" $
      concatMap (`closestDifferences` export "/ip service\nset ssh address=192.168.99.0/24\n") (configuration "/ip service\nset telnet address=192.168.99.0/24\n")
        `shouldBe` ["Nothing the router has in /ip service has name=telnet."]

    it "says when the router has nothing of the kind" $
      concatMap (`closestDifferences` export "/ip service\nset ssh address=192.168.99.0/24\n") (configuration "/ip firewall filter\nadd chain=input\n")
        `shouldBe` ["The router has no add in /ip firewall filter at all."]

  describe "lookUp" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "says everything it finds" $ do
      let asked = configuration "/ip firewall filter\nremove [ find comment=old ]\nadd chain=input action=accept comment=a\nadd chain=input action=drop comment=b\n/system identity\nset name=wanted\n:delay 1s\n"
      let has = export "/ip firewall filter\nadd action=drop chain=input comment=b\nadd action=accept chain=input comment=a\nadd action=accept chain=input comment=old\n/system identity\nset name=other\n"
      lookUp asked has
        `shouldBe` case (asked, has) of
          ([removal, first, second, identity, _], [_, _, old, _]) ->
            Report
              { reportLookedUp = 3,
                reportMissing = [(identity, ["The closest one on the router has name=other, not wanted."])],
                reportOutOfOrder = [(second, first)],
                reportUnasked = [old],
                reportLeftOver = [(removal, old)],
                reportNotLookedUp = Map.fromList [(":delay commands", 1)]
              }
          _ -> Report 0 [] [] [] [] Map.empty

  describe "reportOutcome" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])

    it "is as configured for a router that has its configuration in itself" $
      forAll (listOf (T.pack <$> listOf1 (elements ['a' .. 'c']))) $ \names ->
        let entries = configuration (T.unlines ("/ip firewall filter" : [T.concat ["add chain=input comment=", name] | name <- names]))
         in reportOutcome (lookUp entries entries) `shouldBe` AsConfigured

    it "is not as configured for a router that lacks a command" $
      reportOutcome (lookUp (configuration "/system identity\nset name=wanted\n") [])
        `shouldBe` NotAsConfigured

  describe "renderReport" $ do
    let configuration = entriesIn (Rel [relfile|configuration.rsc|])
    let export = entriesIn (Rel [relfile|export-verbose.rsc|])

    it "renders everything it finds as its golden output does" $
      pureGoldenTextFile "test_resources/postflight/finds-everything.txt" $
        renderChunksText WithoutColours . unlinesChunks . renderReport $
          lookUp
            (configuration "/ip firewall filter\nremove [ find comment=old ]\nadd chain=input action=accept comment=a\nadd chain=input action=drop comment=b\n/system identity\nset name=wanted\n:delay 1s\n")
            (export "/ip firewall filter\nadd action=drop chain=input comment=b\nadd action=accept chain=input comment=a\nadd action=accept chain=input comment=old\n/system identity\nset name=other\n")

    it "renders a router as configured as its golden output does" $
      pureGoldenTextFile "test_resources/postflight/as-configured.txt" $
        renderChunksText WithoutColours . unlinesChunks . renderReport $
          lookUp (configuration "/system identity\nset name=wanted\n") (export "/system identity\nset name=wanted\n")
