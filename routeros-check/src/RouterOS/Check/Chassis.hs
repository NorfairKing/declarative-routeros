{-# LANGUAGE OverloadedStrings #-}

module RouterOS.Check.Chassis
  ( Chassis (..),
  )
where

import Data.Aeson
import Data.Text (Text)

data Chassis = Chassis
  { chassisBoardName :: !Text,
    chassisArchitectureName :: !Text,
    chassisVersion :: !Text,
    -- | Default names, in the order the router numbers them.
    chassisInterfaces :: ![Text],
    -- | @\/port@ has one entry per serial port.
    chassisSerialPorts :: !Int
  }

instance FromJSON Chassis where
  parseJSON = withObject "Chassis" $ \o ->
    Chassis
      <$> o .: "boardName"
      <*> o .: "architectureName"
      <*> o .: "version"
      <*> o .: "interfaces"
      <*> o .: "serialPorts"
