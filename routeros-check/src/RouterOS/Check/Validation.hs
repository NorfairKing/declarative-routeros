{-# LANGUAGE OverloadedStrings #-}

-- | Every problem at once, because the file being checked resets a router.
-- Deliberately not a 'Monad': @>>=@ would stop at the first failure.
module RouterOS.Check.Validation
  ( Validation (..),
    validationFailure,
    ToReport (..),
    renderProblems,
    dieWithProblems,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Error.Diagnose
import Path
import Prettyprinter (defaultLayoutOptions, layoutSmart)
import Prettyprinter.Render.Terminal (renderStrict)
import System.Exit (exitFailure)
import System.IO (Handle, hSetEncoding, utf8)

data Validation e a
  = Failure !(NonEmpty e)
  | Success !a

instance Functor (Validation e) where
  fmap _ (Failure es) = Failure es
  fmap f (Success a) = Success (f a)

instance Applicative (Validation e) where
  pure = Success
  Failure es1 <*> b = Failure $ case b of
    Failure es2 -> es1 <> es2
    Success _ -> es1
  Success _ <*> Failure es2 = Failure es2
  Success f <*> Success a = Success (f a)

validationFailure :: e -> Validation e a
validationFailure e = Failure (e :| [])

class ToReport e where
  toReport :: e -> Report String

-- | Coloured unconditionally, so what the goldens compare is what a reader
-- sees.
renderProblems :: (ToReport e) => SomeBase File -> String -> NonEmpty e -> Text
renderProblems path contents problems =
  let diagnostic =
        foldl
          addReport
          -- diagnose wants a String for the name it quotes lines under.
          (addFile mempty (fromSomeFile path) contents)
          (map toReport (NE.toList problems))
      rendered =
        renderStrict
          ( layoutSmart
              defaultLayoutOptions
              (defaultStyle <$> prettyDiagnostic WithUnicode (TabSize 2) diagnostic)
          )
      counted = case NE.length problems of
        1 -> "1 problem. Do not apply this file."
        n -> T.pack (unwords [show n, "problems. Do not apply this file."])
   in T.concat [rendered, counted, "\n"]

dieWithProblems :: (ToReport e) => Handle -> SomeBase File -> String -> NonEmpty e -> IO a
dieWithProblems handle path contents problems = do
  -- The box drawing is not ASCII and a build sandbox has no locale.
  hSetEncoding handle utf8
  TIO.hPutStr handle (renderProblems path contents problems)
  exitFailure
