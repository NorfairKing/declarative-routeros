{-# LANGUAGE OverloadedStrings #-}

module RouterOS.ImagesSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import RouterOS.Images
import Test.QuickCheck (choose, forAll)
import Test.Syd

spec :: Spec
spec = do
  describe "releaseText" $ do
    it "names a release without a patch the way MikroTik does" $
      releaseText (Version 15 0) `shouldBe` "7.15"

    it "names a patch release" $
      releaseText (Version 25 1) `shouldBe` "7.25.1"

  describe "imageOf" $
    it "is where MikroTik keeps the arm64 image of a release" $
      imageOf (Version 21 0) (Sha256 "7a76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17")
        `shouldBe` Image
          { imageUrl = "https://download.mikrotik.com/routeros/7.21/chr-7.21-arm64.img.zip",
            imageSha256 = Sha256 "7a76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17"
          }

  describe "checksumUrlOf" $
    it "is next to the image" $
      checksumUrlOf (Version 25 1)
        `shouldBe` "https://download.mikrotik.com/routeros/7.25.1/chr-7.25.1-arm64.img.zip.sha256"

  describe "nextToProbe" $ do
    it "starts at the release without a patch" $
      nextToProbe 15 [] `shouldBe` Just (Version 15 0)

    it "goes on past one release without an image" $
      nextToProbe 15 [Found, Missing] `shouldBe` Just (Version 15 2)

    it "stops after two releases in a row without one" $
      nextToProbe 15 [Found, Found, Missing, Missing] `shouldBe` Nothing

    it "stops at a minor version with no image at all" $
      nextToProbe 11 [Missing, Missing] `shouldBe` Nothing

  describe "parseChecksum" $ do
    it "reads the checksum MikroTik publishes" $
      parseChecksum (Version 21 0) "7A76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17  chr-7.21-arm64.img.zip\n"
        `shouldBe` Right (Sha256 "7a76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17")

    it "refuses a checksum of some other file" $
      parseChecksum (Version 21 0) "7a76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17  chr-7.21.img.zip\n"
        `shouldBe` Left "expected a sha256 of chr-7.21-arm64.img.zip, got \"7a76d2ea13cea87a63842b9401657e51c886fb7aef452a29d2d231e0d4d57a17  chr-7.21.img.zip\""

    it "refuses a page that is not a checksum" $
      parseChecksum (Version 21 0) "<html>Not Found</html>"
        `shouldBe` Left "expected a sha256 of chr-7.21-arm64.img.zip, got \"<html>Not Found</html>\""

  describe "parseNewest" $ do
    it "reads every release the way releaseText names it" $
      forAll ((,) <$> choose (0, 100) <*> choose (0, 20)) $ \(minor, patch) -> do
        let version =
              Version
                { versionMinor = minor,
                  versionPatch = patch
                }
        parseNewest (T.unwords [releaseText version, "1793623193"]) `shouldBe` Right version

    it "reads a patch release" $
      parseNewest "7.25.1 1793623193\n" `shouldBe` Right (Version 25 1)

    it "reads a release without a patch" $
      parseNewest "7.26 1793623193\n" `shouldBe` Right (Version 26 0)

    it "refuses anything else" $
      parseNewest "<html>Not Found</html>"
        `shouldBe` Left "expected a RouterOS 7 release, got \"<html>Not Found</html>\""

    it "refuses RouterOS 6" $
      parseNewest "6.49.10 1793623193"
        `shouldBe` Left "expected a RouterOS 7 release, got \"6.49.10 1793623193\""

  describe "renderImages" $
    it "writes what nix/chr-images.json holds" $
      pureGoldenLazyByteStringFile "test_resources/chr-images.json" $
        renderImages $
          Map.fromList
            [ ("7.15", imageOf (Version 15 0) (Sha256 "1111111111111111111111111111111111111111111111111111111111111111")),
              ("7.15.1", imageOf (Version 15 1) (Sha256 "2222222222222222222222222222222222222222222222222222222222222222"))
            ]
