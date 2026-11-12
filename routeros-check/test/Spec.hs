module Main (main) where

import qualified RouterOS.CheckSpec
import qualified RouterOS.ImagesSpec
import Test.Syd

main :: IO ()
main = sydTest $ do
  RouterOS.CheckSpec.spec
  RouterOS.ImagesSpec.spec
