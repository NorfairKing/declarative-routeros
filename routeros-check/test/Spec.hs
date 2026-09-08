module Main (main) where

import qualified RouterOS.CheckSpec
import Test.Syd

main :: IO ()
main = sydTest RouterOS.CheckSpec.spec
