-- | Main Toss logic.

module Pos.Ssc.GodTossing.Toss.Logic
       ( verifyAndApplySscPayload
       , applyGenesisBlock
       , rollbackGT
       , normalizeToss
       , refreshToss
       ) where

import           Control.Lens                     (at)
import           Control.Monad.Except             (MonadError, runExceptT)
import           Crypto.Random                    (MonadRandom)
import qualified Data.HashMap.Strict              as HM
import           System.Wlog                      (logError)
import           Universum

import           Pos.Core                         (EpochIndex, EpochOrSlot (..),
                                                   HasConfiguration, IsMainHeader,
                                                   LocalSlotIndex, SlotCount,
                                                   SlotId (siSlot), StakeholderId,
                                                   VssCertificate, epochIndexL,
                                                   epochOrSlot, getEpochOrSlot,
                                                   getVssCertificatesMap, headerSlotL,
                                                   mkCoin, mkVssCertificatesMapSingleton,
                                                   slotSecurityParam)
import           Pos.Ssc.GodTossing.Configuration (HasGtConfiguration)
import           Pos.Ssc.Core                     (CommitmentsMap (..), SscPayload (..),
                                                   InnerSharesMap, Opening,
                                                   SignedCommitment, getCommitmentsMap,
                                                   spVss, mkCommitmentsMapUnsafe)
import           Pos.Ssc.GodTossing.Functions     (verifySscPayload)
import           Pos.Ssc.GodTossing.Toss.Base     (checkPayload)
import           Pos.Ssc.GodTossing.Toss.Class    (MonadToss (..), MonadTossEnv (..))
import           Pos.Ssc.VerifyError              (SscVerifyError (..))
import           Pos.Ssc.GodTossing.Toss.Types    (TossModifier (..))
import           Pos.Util.Chrono                  (NewestFirst (..))
import           Pos.Util.Util                    (Some, inAssertMode, sortWithMDesc)

-- | Verify 'SscPayload' with respect to data provided by
-- MonadToss. If data is valid it is also applied.  Otherwise
-- SscVerifyError is thrown using 'MonadError' type class.
verifyAndApplySscPayload
    :: (HasGtConfiguration, HasConfiguration, MonadToss m, MonadTossEnv m,
        MonadError SscVerifyError m, MonadRandom m)
    => Either EpochIndex (Some IsMainHeader) -> SscPayload -> m ()
verifyAndApplySscPayload eoh payload = do
    -- We can't trust payload from mempool, so we must call
    -- @verifySscPayload@.
    whenLeft eoh $ const $ verifySscPayload eoh payload
    -- We perform @verifySscPayload@ for block when we construct it
    -- (in the 'recreateGenericBlock').  So this check is just in case.
    inAssertMode $
        whenRight eoh $ const $ verifySscPayload eoh payload
    let blockCerts = spVss payload
    let curEpoch = either identity (^. epochIndexL) eoh
    checkPayload curEpoch payload

    -- Apply
    case eoh of
        Left _       -> pass
        Right header -> do
            let eos = EpochOrSlot $ Right $ header ^. headerSlotL
            setEpochOrSlot eos
            -- We can freely clear shares after 'slotSecurityParam' because
            -- it's guaranteed that rollback on more than 'slotSecurityParam'
            -- can't happen
            let indexToCount :: LocalSlotIndex -> SlotCount
                indexToCount = fromIntegral . fromEnum
            let slot = epochOrSlot (const 0) (indexToCount . siSlot) eos
            when (slotSecurityParam <= slot && slot < 2 * slotSecurityParam) $
                resetShares
    mapM_ putCertificate blockCerts
    case payload of
        CommitmentsPayload  comms  _ ->
            mapM_ putCommitment $ toList $ getCommitmentsMap comms
        OpeningsPayload     opens  _ ->
            mapM_ (uncurry putOpening) $ HM.toList opens
        SharesPayload       shares _ ->
            mapM_ (uncurry putShares) $ HM.toList shares
        CertificatesPayload        _ ->
            pass

-- | Apply genesis block for given epoch to 'Toss' state.
applyGenesisBlock :: MonadToss m => EpochIndex -> m ()
applyGenesisBlock epoch = do
    setEpochOrSlot $ getEpochOrSlot epoch
    -- We don't clear shares on genesis block because
    -- there aren't 'slotSecurityParam' slots after shares phase,
    -- so we won't have shares after rollback
    -- We store shares until 'slotSecurityParam' slots of next epoch passed
    -- and clear their after that
    resetCO

-- | Rollback application of 'SscPayload's in 'Toss'. First argument is
-- 'EpochOrSlot' of oldest block which is subject to rollback.
rollbackGT :: (HasConfiguration, MonadToss m) => EpochOrSlot -> NewestFirst [] SscPayload -> m ()
rollbackGT oldestEOS (NewestFirst payloads)
    | oldestEOS == toEnum 0 = do
        logError "rollbackGT: most genesis block is passed to rollback"
        setEpochOrSlot oldestEOS
        resetCO
        resetShares
    | otherwise = do
        setEpochOrSlot (pred oldestEOS)
        mapM_ rollbackGTDo payloads
  where
    rollbackGTDo (CommitmentsPayload comms _) =
        mapM_ delCommitment $ HM.keys $ getCommitmentsMap comms
    rollbackGTDo (OpeningsPayload opens _) = mapM_ delOpening $ HM.keys opens
    rollbackGTDo (SharesPayload shares _) = mapM_ delShares $ HM.keys shares
    rollbackGTDo (CertificatesPayload _) = pass

-- | Apply as much data from given 'TossModifier' as possible.
normalizeToss
    :: (HasGtConfiguration, HasConfiguration, MonadToss m, MonadTossEnv m, MonadRandom m)
    => EpochIndex -> TossModifier -> m ()
normalizeToss epoch TossModifier {..} =
    normalizeTossDo
        epoch
        ( HM.toList (getCommitmentsMap _tmCommitments)
        , HM.toList _tmOpenings
        , HM.toList _tmShares
        , HM.toList (getVssCertificatesMap _tmCertificates))

-- | Apply the most valuable from given 'TossModifier' and drop the
-- rest. This function can be used if mempool is exhausted.
refreshToss
    :: (HasGtConfiguration, HasConfiguration, MonadToss m, MonadTossEnv m, MonadRandom m)
    => EpochIndex -> TossModifier -> m ()
refreshToss epoch TossModifier {..} = do
    comms <-
        takeMostValuable epoch (HM.toList (getCommitmentsMap _tmCommitments))
    opens <- takeMostValuable epoch (HM.toList _tmOpenings)
    shares <- takeMostValuable epoch (HM.toList _tmShares)
    certs <- takeMostValuable epoch (HM.toList (getVssCertificatesMap _tmCertificates))
    normalizeTossDo epoch (comms, opens, shares, certs)

takeMostValuable
    :: (MonadToss m, MonadTossEnv m)
    => EpochIndex
    -> [(StakeholderId, x)]
    -> m [(StakeholderId, x)]
takeMostValuable epoch items = take toTake <$> sortWithMDesc resolver items
  where
    toTake = 2 * length items `div` 3
    resolver (id, _) =
        fromMaybe (mkCoin 0) . (view (at id)) . fromMaybe mempty <$>
        getRichmen epoch

type TossModifierLists
     = ( [(StakeholderId, SignedCommitment)]
       , [(StakeholderId, Opening)]
       , [(StakeholderId, InnerSharesMap)]
       , [(StakeholderId, VssCertificate)])

normalizeTossDo
    :: forall m.
       (HasGtConfiguration, HasConfiguration, MonadToss m, MonadTossEnv m, MonadRandom m)
    => EpochIndex -> TossModifierLists -> m ()
normalizeTossDo epoch (comms, opens, shares, certs) = do
    putsUseful $
        map (flip CommitmentsPayload mempty . mkCommitmentsMapUnsafe . one) $
        comms
    putsUseful $ map (flip OpeningsPayload mempty . one) opens
    putsUseful $ map (flip SharesPayload mempty . one) shares
    putsUseful $ map (CertificatesPayload . mkVssCertificatesMapSingleton . snd) certs
  where
    putsUseful :: [SscPayload] -> m ()
    putsUseful entries = do
        let verifyAndApply = runExceptT . verifyAndApplySscPayload (Left epoch)
        mapM_ verifyAndApply entries
