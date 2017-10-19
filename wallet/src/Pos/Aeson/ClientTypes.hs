module Pos.Aeson.ClientTypes
       (
       ) where

import           Data.Aeson                   (ToJSON (..), object, (.=))
import           Data.Aeson.TH                (defaultOptions, deriveJSON, deriveToJSON)
import           Universum

import           Pos.Core.Types               (SoftwareVersion (..))
import           Pos.Launcher                 (gitRev)
import           Pos.Util.BackupPhrase        (BackupPhrase)
import           Pos.Wallet.Web.ClientTypes   (Addr, ApiVersion (..), CAccount,
                                               CAccountId, CAccountInit, CAccountMeta,
                                               CAddress, CCoin, CHash, CId, CInitialized,
                                               CPaperVendWalletRedeem, CProfile,
                                               CPtxCondition, CTExMeta, CTx, CTxId,
                                               CTxMeta, CUpdateInfo, CWAddressMeta,
                                               CWallet, CWalletAssurance, CWalletInit,
                                               CWalletMeta, CWalletRedeem, SyncProgress,
                                               Wal)
import           Pos.Wallet.Web.Error         (WalletError)
import           Pos.Wallet.Web.Sockets.Types (NotifyEvent)

deriveJSON defaultOptions ''CAccountId
deriveJSON defaultOptions ''CWAddressMeta
deriveJSON defaultOptions ''CWalletAssurance
deriveJSON defaultOptions ''CAccountMeta
deriveJSON defaultOptions ''CAccountInit
deriveJSON defaultOptions ''CWalletRedeem
deriveJSON defaultOptions ''CWalletMeta
deriveJSON defaultOptions ''CWalletInit
deriveJSON defaultOptions ''CPaperVendWalletRedeem
deriveJSON defaultOptions ''CTxMeta
deriveJSON defaultOptions ''CProfile
deriveJSON defaultOptions ''BackupPhrase
deriveJSON defaultOptions ''CId
deriveJSON defaultOptions ''Wal
deriveJSON defaultOptions ''Addr
deriveJSON defaultOptions ''CHash
deriveJSON defaultOptions ''CInitialized

deriveJSON defaultOptions ''CCoin
deriveJSON defaultOptions ''CTxId
deriveJSON defaultOptions ''CAddress
deriveJSON defaultOptions ''CAccount
deriveJSON defaultOptions ''CWallet
deriveJSON defaultOptions ''CPtxCondition
deriveJSON defaultOptions ''CTx
deriveJSON defaultOptions ''CTExMeta
deriveJSON defaultOptions ''SoftwareVersion
deriveJSON defaultOptions ''CUpdateInfo

deriveToJSON defaultOptions ''SyncProgress
deriveToJSON defaultOptions ''NotifyEvent
deriveToJSON defaultOptions ''WalletError

instance ToJSON ApiVersion where
    toJSON ApiVersion0 =
        object ["version" .= versionName, "gitRev" .= gitRev]
      where
        versionName :: Text
        versionName = "v0"
