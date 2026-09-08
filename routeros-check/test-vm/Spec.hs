module Main (main) where

import qualified RouterOS.ToolSpec
import Test.Syd

main :: IO ()
main = sydTest RouterOS.ToolSpec.spec
