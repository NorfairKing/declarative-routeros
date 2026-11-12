{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

module RouterOS.Postflight.OptParse
  ( getInstructions,
    Instructions (..),
  )
where

import OptEnvConf
import Path
import Paths_routeros_check (version)

getInstructions :: IO Instructions
getInstructions =
  runSettingsParser
    version
    "say which commands of a configuration a router's verbose export does not have"

data Instructions = Instructions
  { instructionsConfiguration :: ![Path Abs File],
    instructionsExport :: !(Path Abs File)
  }

instance HasParser Instructions where
  settingsParser = do
    instructionsConfiguration <-
      some $
        filePathSetting
          [ help "a configuration file that was applied; each of its commands is looked up on its own, so one a later command undid is reported",
            option,
            long "configuration"
          ]
    instructionsExport <-
      filePathSetting
        [ help "a verbose export of the router it was applied to, as a download records it",
          argument
        ]
    pure Instructions {..}
