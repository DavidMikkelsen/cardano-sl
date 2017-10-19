-- | API version.

module Pos.Wallet.Web.Methods.Version
       ( getApiVersion
       ) where

import           Universum

import           Pos.Wallet.Web.ClientTypes (ApiVersion (..))

getApiVersion :: Applicative m => m ApiVersion
getApiVersion = pure ApiVersion0
