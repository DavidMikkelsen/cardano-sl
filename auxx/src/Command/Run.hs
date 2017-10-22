{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes    #-}
{-# OPTIONS -fno-warn-unused-imports #-} -- TODO: remove

-- | This module provides a function to run Auxx's command.

module Command.Run
       ( runCmd
       ) where

import           Universum

import           Data.ByteString.Base58     (bitcoinAlphabet, encodeBase58)
import           Data.List                  ((!!))
import           Formatting                 (build, int, sformat, stext, (%))
import           System.Wlog                (logError, logInfo)
import qualified Text.JSON.Canonical        as CanonicalJSON

import           Pos.Binary                 (serialize')
import           Pos.Client.KeyStorage      (addSecretKey, getSecretKeysPlain)
import           Pos.Client.Txp.Balances    (getBalance)
import           Pos.Communication          (MsgType (..), Origin (..), SendActions,
                                             dataFlow, immediateConcurrentConversations)
import           Pos.Core                   (addressHash, coinF)
import           Pos.Core.Address           (makeAddress)
import           Pos.Core.Configuration     (genesisSecretKeys)
import           Pos.Core.Types             (AddrAttributes (..), AddrSpendingData (..))
import           Pos.Crypto                 (emptyPassphrase, encToPublic,
                                             fullPublicKeyHexF, hashHexF, noPassEncrypt,
                                             safeCreatePsk, withSafeSigner)
import           Pos.DB.Class               (MonadGState (..))
import           Pos.Launcher.Configuration (HasConfigurations)
import           Pos.Util.CompileInfo       (HasCompileInfo)
import           Pos.Util.UserSecret        (WalletUserSecret (..), readUserSecret,
                                             usKeys, usWallet, userSecret)

import           Command.BlockGen           (generateBlocks)
import           Command.Help               (helpMessage)
import qualified Command.Rollback           as Rollback
import qualified Command.Tx                 as Tx
import           Command.Types              (Command (..), PrintAction)
import qualified Command.Update             as Update
import           Mode                       (AuxxMode, CmdCtx (..), deriveHDAddressAuxx,
                                             getCmdCtx, makePubKeyAddressAuxx)


-- FIXME: remove this
runCmd
    :: ( HasConfigurations
       , HasCompileInfo
       )
    => Command
    -> PrintAction AuxxMode
    -> SendActions AuxxMode
    -> AuxxMode ()
runCmd cmd printAction sendActions = case cmd of

    Send idx outputs ->
        Tx.send sendActions idx outputs

    SendToAllGenesis stagp ->
        Tx.sendToAllGenesis sendActions stagp

    Vote idx decision upId ->
        Update.vote sendActions idx decision upId

    ProposeUpdate params ->
        Update.propose sendActions params

    DelegateLight i delegatePk startEpoch lastEpochM -> do
        CmdCtx{ccPeers} <- getCmdCtx
        issuerSk <- (!! i) <$> getSecretKeysPlain
        withSafeSigner issuerSk (pure emptyPassphrase) $ \case
            Nothing -> logError "Invalid passphrase"
            Just ss -> do
                let psk = safeCreatePsk ss delegatePk (startEpoch, fromMaybe 1000 lastEpochM)
                dataFlow
                    "pskLight"
                    (immediateConcurrentConversations sendActions ccPeers)
                    (MsgTransaction OriginSender) psk
                logInfo "Sent lightweight cert"

    DelegateHeavy i delegatePk curEpoch dry -> do
        CmdCtx {ccPeers} <- getCmdCtx
        issuerSk <- (!! i) <$> getSecretKeysPlain
        withSafeSigner issuerSk (pure emptyPassphrase) $ \case
            Nothing -> logError "Invalid passphrase"
            Just ss -> do
                let psk = safeCreatePsk ss delegatePk curEpoch
                if dry
                then do
                    printAction $
                        sformat ("JSON: key "%hashHexF%", value "%stext)
                            (addressHash $ encToPublic issuerSk)
                            (decodeUtf8 $
                                CanonicalJSON.renderCanonicalJSON $
                                runIdentity $
                                CanonicalJSON.toJSON psk)
                else do
                    dataFlow
                        "pskHeavy"
                        (immediateConcurrentConversations sendActions ccPeers)
                        (MsgTransaction OriginSender)
                        psk
                    logInfo "Sent heavyweight cert"

    AddKeyFromPool i -> do
        CmdCtx {..} <- getCmdCtx
        let secrets = fromMaybe (error "Secret keys are unknown") genesisSecretKeys
        let key = secrets !! i
        addSecretKey $ noPassEncrypt key

    AddrDistr pk asd -> do
        let addr = makeAddress (PubKeyASD pk) (AddrAttributes Nothing asd)
        printAction $ pretty addr

    Rollback rollbackNum rollbackDumpPath ->
        Rollback.rollbackAndDump rollbackNum rollbackDumpPath

    GenBlocks params ->
        generateBlocks params
