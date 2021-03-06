{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP                 #-}

-- | Internal block logic. Mostly needed for use in 'Pos.Lrc' -- using
-- lrc requires to apply and rollback blocks, but applying many blocks
-- requires triggering lrc recalculations.

module Pos.Block.Logic.Internal
       (
         -- * Constraints
         MonadBlockBase
       , MonadBlockVerify
       , MonadBlockApply
       , MonadMempoolNormalization

       , applyBlocksUnsafe
       , normalizeMempool
       , rollbackBlocksUnsafe
       , BypassSecurityCheck(..)

         -- * Garbage
       , toUpdateBlock
       , toTxpBlock
       ) where

import           Universum

import           Control.Lens            (each, _Wrapped)
import qualified Crypto.Random           as Rand
import           Ether.Internal          (lensOf)
import           Formatting              (sformat, (%))
import           Mockable                (CurrentTime, Mockable)
import           Serokell.Util.Text      (listJson)

import           Pos.Block.BListener     (MonadBListener)
import           Pos.Block.Core          (Block, GenesisBlock, MainBlock, mbTxPayload,
                                          mbUpdatePayload)
import           Pos.Block.Slog          (BypassSecurityCheck (..), MonadSlogApply,
                                          MonadSlogBase, ShouldCallBListener,
                                          slogApplyBlocks, slogRollbackBlocks)
import           Pos.Block.Types         (Blund, Undo (undoTx, undoUS))
import           Pos.Core                (HasConfiguration, IsGenesisHeader, IsMainHeader,
                                          epochIndexL, gbBody, gbHeader, headerHash)
import           Pos.DB                  (MonadDB, MonadGState, SomeBatchOp (..))
import           Pos.DB.Block            (MonadBlockDB, MonadSscBlockDB)
import           Pos.DB.DB               (sanityCheckDB)
import           Pos.Delegation.Class    (MonadDelegation)
import           Pos.Delegation.Logic    (dlgApplyBlocks, dlgNormalizeOnRollback,
                                          dlgRollbackBlocks)
import           Pos.Exception           (assertionFailed)
import qualified Pos.GState              as GS
import           Pos.Lrc.Context         (HasLrcContext)
import           Pos.Reporting           (MonadReporting)
import           Pos.Ssc.Extra           (MonadSscMem, sscApplyBlocks, sscNormalize,
                                          sscRollbackBlocks)
import           Pos.Ssc.GodTossing      (HasGtConfiguration)
import           Pos.Ssc.Util            (toSscBlock)
import           Pos.Txp.Core            (TxPayload)
import           Pos.Txp.MemState        (MonadTxpLocal (..))
import           Pos.Txp.Settings        (TxpBlock, TxpBlund, TxpGlobalSettings (..))
import           Pos.Update.Context      (UpdateContext)
import           Pos.Update.Core         (UpdateBlock, UpdatePayload)
import           Pos.Update.Logic        (usApplyBlocks, usNormalize, usRollbackBlocks)
import           Pos.Update.Poll         (PollModifier)
import           Pos.Util                (HasLens', Some (..), spanSafe)
import           Pos.Util.Chrono         (NE, NewestFirst (..), OldestFirst (..))

-- | Set of basic constraints used by high-level block processing.
type MonadBlockBase ctx m
     = ( MonadSlogBase ctx m
       -- Needed because SSC state is fully stored in memory.
       , MonadSscMem ctx m
       -- Needed to load blocks (at least delegation does it).
       , MonadBlockDB m
       , MonadSscBlockDB m
       -- Needed by some components.
       , MonadGState m
       -- This constraints define block components' global logic.
       , HasLrcContext ctx
       , HasLens' ctx TxpGlobalSettings
       , MonadDelegation ctx m
       -- 'MonadRandom' for crypto.
       , Rand.MonadRandom m
       -- To report bad things.
       , MonadReporting ctx m
       , HasGtConfiguration
       )

-- | Set of constraints necessary for high-level block verification.
type MonadBlockVerify ctx m = MonadBlockBase ctx m

-- | Set of constraints necessary to apply or rollback blocks at high-level.
-- Also normalize mempool.
type MonadBlockApply ctx m
     = ( MonadBlockBase ctx m
       , MonadSlogApply ctx m
       -- It's obviously needed to write something to DB, for instance.
       , MonadDB m
       -- Needed for iteration over DB.
       , MonadMask m
       -- Needed to embed custom logic.
       , MonadBListener m
       -- Needed for rollback
       , Mockable CurrentTime m
       )

type MonadMempoolNormalization ctx m
    = ( MonadSlogBase ctx m
      , MonadTxpLocal m
      , MonadSscMem ctx m
      , HasLrcContext ctx
      , HasLens' ctx UpdateContext
      -- Needed to load useful information from db
      , MonadBlockDB m
      , MonadSscBlockDB m
      , MonadGState m
      -- Needed for error reporting.
      , MonadReporting ctx m
      -- 'MonadRandom' for crypto.
      , Rand.MonadRandom m
      , Mockable CurrentTime m
      , HasGtConfiguration
      )

-- | Normalize mempool.
normalizeMempool
    :: forall ctx m . (MonadMempoolNormalization ctx m)
    => m ()
normalizeMempool = do
    -- We normalize all mempools except the delegation one.
    -- That's because delegation mempool normalization is harder and is done
    -- within block application.
    sscNormalize
    txpNormalize
    usNormalize

-- | Applies a definitely valid prefix of blocks. This function is unsafe,
-- use it only if you understand what you're doing. That means you can break
-- system guarantees.
--
-- Invariant: all blocks have the same epoch.
applyBlocksUnsafe
    :: forall ctx m . (MonadBlockApply ctx m)
    => ShouldCallBListener
    -> OldestFirst NE Blund
    -> Maybe PollModifier
    -> m ()
applyBlocksUnsafe scb blunds pModifier = do
    -- Check that all blunds have the same epoch.
    unless (null nextEpoch) $ assertionFailed $
        sformat ("applyBlocksUnsafe: tried to apply more than we should"%
                 "thisEpoch"%listJson%"\nnextEpoch:"%listJson)
                (map (headerHash . fst) thisEpoch)
                (map (headerHash . fst) nextEpoch)
    -- It's essential to apply genesis block separately, before
    -- applying other blocks.
    -- That's because applying genesis block may change protocol version
    -- which may potentially change protocol rules.
    -- We would like to avoid dependencies between components, so we have
    -- chosen this approach. Related issue is CSL-660.
    -- Also note that genesis block can be only in the head, because all
    -- blocks are from the same epoch.
    case blunds ^. _Wrapped of
        (b@(Left _,_):|[])     -> app' (b:|[])
        (b@(Left _,_):|(x:xs)) -> app' (b:|[]) >> app' (x:|xs)
        _                      -> app blunds
  where
    app x = applyBlocksDbUnsafeDo scb x pModifier
    app' = app . OldestFirst
    (thisEpoch, nextEpoch) =
        spanSafe ((==) `on` view (_1 . epochIndexL)) $ getOldestFirst blunds

applyBlocksDbUnsafeDo
    :: forall ctx m . (MonadBlockApply ctx m)
    => ShouldCallBListener
    -> OldestFirst NE Blund
    -> Maybe PollModifier
    -> m ()
applyBlocksDbUnsafeDo scb blunds pModifier = do
    let blocks = fmap fst blunds
    -- Note: it's important to do 'slogApplyBlocks' first, because it
    -- puts blocks in DB.
    slogBatch <- slogApplyBlocks scb blunds
    TxpGlobalSettings {..} <- view (lensOf @TxpGlobalSettings)
    usBatch <- SomeBatchOp <$> usApplyBlocks (map toUpdateBlock blocks) pModifier
    delegateBatch <- SomeBatchOp <$> dlgApplyBlocks blunds
    txpBatch <- tgsApplyBlocks $ map toTxpBlund blunds
    sscBatch <- SomeBatchOp <$>
        -- TODO: pass not only 'Nothing'
        sscApplyBlocks (map toSscBlock blocks) Nothing
    GS.writeBatchGState
        [ delegateBatch
        , usBatch
        , txpBatch
        , sscBatch
        , slogBatch
        ]
    sanityCheckDB

-- | Rollback sequence of blocks, head-newest order expected with head being
-- current tip. It's also assumed that lock on block db is taken already.
rollbackBlocksUnsafe
    :: forall ctx m. (MonadBlockApply ctx m)
    => BypassSecurityCheck -- ^ is rollback for more than k blocks allowed?
    -> ShouldCallBListener
    -> NewestFirst NE Blund
    -> m ()
rollbackBlocksUnsafe bsc scb toRollback = do
    slogRoll <- slogRollbackBlocks bsc scb toRollback
    dlgRoll <- SomeBatchOp <$> dlgRollbackBlocks toRollback
    usRoll <- SomeBatchOp <$> usRollbackBlocks
                  (toRollback & each._2 %~ undoUS
                              & each._1 %~ toUpdateBlock)
    TxpGlobalSettings {..} <- view (lensOf @TxpGlobalSettings)
    txRoll <- tgsRollbackBlocks $ map toTxpBlund toRollback
    sscBatch <- SomeBatchOp <$> sscRollbackBlocks
        (map (toSscBlock . fst) toRollback)
    GS.writeBatchGState
        [ dlgRoll
        , usRoll
        , txRoll
        , sscBatch
        , slogRoll
        ]
    -- After blocks are rolled back it makes sense to recreate the
    -- delegation mempool.
    -- We don't normalize other mempools, because they are normalized
    -- in 'applyBlocksUnsafe' and we always ensure that some blocks
    -- are applied after rollback.
    dlgNormalizeOnRollback
    sanityCheckDB

----------------------------------------------------------------------------
-- Garbage
----------------------------------------------------------------------------

-- [CSL-1156] Need something more elegant.
toTxpBlock
    :: HasConfiguration
    => Block -> TxpBlock
toTxpBlock = bimap convertGenesis convertMain
  where
    convertGenesis :: GenesisBlock -> Some IsGenesisHeader
    convertGenesis = Some . view gbHeader
    convertMain :: MainBlock -> (Some IsMainHeader, TxPayload)
    convertMain blk = (Some $ blk ^. gbHeader, blk ^. gbBody . mbTxPayload)

-- [CSL-1156] Yes, definitely need something more elegant.
toTxpBlund
    :: HasConfiguration
    => Blund -> TxpBlund
toTxpBlund = bimap toTxpBlock undoTx

-- [CSL-1156] Sure, totally need something more elegant
toUpdateBlock
    :: HasConfiguration
    => Block -> UpdateBlock
toUpdateBlock = bimap convertGenesis convertMain
  where
    convertGenesis :: GenesisBlock -> Some IsGenesisHeader
    convertGenesis = Some . view gbHeader
    convertMain :: MainBlock -> (Some IsMainHeader, UpdatePayload)
    convertMain blk = (Some $ blk ^. gbHeader, blk ^. gbBody . mbUpdatePayload)
