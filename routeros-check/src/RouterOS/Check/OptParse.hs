{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

module RouterOS.Check.OptParse
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
    "check a RouterOS configuration file before applying it resets a router"

data Instructions = Instructions
  { instructionsScript :: !(Path Abs File),
    instructionsHosts :: !(Path Abs File),
    instructionsChassis :: !(Maybe (Path Abs File)),
    instructionsExport :: !(Maybe (Path Abs File)),
    instructionsOutputDir :: !(Path Abs Dir)
  }

instance HasParser Instructions where
  settingsParser = do
    instructionsScript <-
      filePathSetting
        [ help "the RouterOS configuration file to read",
          argument
        ]
    instructionsHosts <-
      filePathSetting
        [ help "JSON list of what else is supposed to be on this network",
          argument
        ]
    instructionsChassis <-
      optional $
        filePathSetting
          [ help "JSON description of what the router is made of, as the router answered",
            option,
            long "chassis"
          ]
    instructionsExport <-
      optional $
        filePathSetting
          [ help "an export of the router's own configuration, which says which words it knows",
            option,
            long "export"
          ]
    instructionsOutputDir <-
      directoryPathSetting
        [ help "where to write what a clean file earns: the file itself, its two halves, and the problems this knows how to find",
          option,
          long "into"
        ]
    pure Instructions {..}
