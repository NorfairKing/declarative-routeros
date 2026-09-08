module RouterOS.Check.Location
  ( Located (..),
    SourceSpan (..),
    SourcePosition (..),
    spanOfLine,
    spanWithin,
    toDiagnosePosition,
  )
where

import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Error.Diagnose.Position as Diagnose (Position (..))
import Path

data Located a = Located
  { locatedLocation :: !SourceSpan,
    locatedValue :: !a
  }

data SourceSpan = SourceSpan
  { -- | Whichever of absolute and relative the reader named it as.
    sourceSpanFile :: !(SomeBase File),
    sourceSpanBegin :: !SourcePosition,
    sourceSpanEnd :: !SourcePosition
  }

data SourcePosition = SourcePosition
  { -- | One-based, which is what diagnose wants and what a reader counting
    -- lines in an editor expects.
    sourcePositionLine :: !Int,
    sourcePositionColumn :: !Int
  }

-- | The indent is measured with the same notion of space the body is stripped
-- with, or a tab-indented line reports the wrong column.
spanOfLine :: SomeBase File -> Int -> Text -> SourceSpan
spanOfLine file line raw =
  let indent = T.length (T.takeWhile isSpace raw)
      body = T.strip raw
   in SourceSpan
        { sourceSpanFile = file,
          sourceSpanBegin = SourcePosition line (indent + 1),
          sourceSpanEnd = SourcePosition line (indent + 1 + max 1 (T.length body))
        }

-- | Anchored to the enclosing span, so a caller can point inside it without
-- knowing the indent.
spanWithin :: SourceSpan -> Int -> Int -> SourceSpan
spanWithin outer offset len =
  let SourcePosition line column = sourceSpanBegin outer
   in outer
        { sourceSpanBegin = SourcePosition line (column + offset),
          sourceSpanEnd = SourcePosition line (column + offset + max 1 len)
        }

toDiagnosePosition :: SourceSpan -> Diagnose.Position
toDiagnosePosition sourceSpan =
  Diagnose.Position
    { Diagnose.begin =
        ( sourcePositionLine (sourceSpanBegin sourceSpan),
          sourcePositionColumn (sourceSpanBegin sourceSpan)
        ),
      Diagnose.end =
        ( sourcePositionLine (sourceSpanEnd sourceSpan),
          sourcePositionColumn (sourceSpanEnd sourceSpan)
        ),
      -- diagnose wants a String, which is what converting at the edge means.
      Diagnose.file = fromSomeFile (sourceSpanFile sourceSpan)
    }
