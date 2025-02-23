{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE StandaloneDeriving  #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

--  This module contains a contract model for positive testing of the
--  simplified escrow contract in Plutus.Contracts.Tutorial.Escrow,
--  with generated escrow targets. See the "Parameterising Models and
--  Dynamic Contract Instances" section of the tutorial.

module Escrow4(prop_Escrow, prop_FinishEscrow, prop_NoLockedFunds, EscrowModel) where

import Control.Lens hiding (both, elements)
import Control.Monad (void, when)
import Data.Data
import Data.Default
import Data.Foldable
import Data.Map (Map)
import Data.Map qualified as Map

import Ledger (Datum, Slot (..), minAdaTxOut)
import Ledger.Ada qualified as Ada
import Ledger.TimeSlot (SlotConfig (..))
import Ledger.Value (Value, geq)
import Plutus.Contract (Contract, selectList)
import Plutus.Contract.Test
import Plutus.Contract.Test.ContractModel
import Plutus.V1.Ledger.Time

import Plutus.Contracts.Escrow hiding (Action (..))
import Plutus.Trace.Emulator qualified as Trace
import PlutusTx.Monoid (inv)

import Test.QuickCheck

{- START EscrowModel -}
data EscrowModel = EscrowModel { _contributions :: Map Wallet Value
                               , _targets       :: Map Wallet Value
                               , _refundSlot    :: Slot             -- NEW!!!
                               , _phase         :: Phase
                               } deriving (Eq, Show, Data)
{- END EscrowModel -}

{- START Phase -}
data Phase = Initial | Running | Refunding deriving (Eq, Show, Data)
{- END Phase -}

makeLenses ''EscrowModel

deriving instance Eq (ContractInstanceKey EscrowModel w s e params)
deriving instance Show (ContractInstanceKey EscrowModel w s e params)

instance ContractModel EscrowModel where

{- START Action -}
  data Action EscrowModel = Init Slot [(Wallet, Integer)]    -- NEW!!!
                          | Redeem Wallet
                          | Pay Wallet Integer
                          | Refund Wallet
    deriving (Eq, Show, Data)
{- END Action -}

  data ContractInstanceKey EscrowModel w s e params where
    WalletKey :: Wallet -> ContractInstanceKey EscrowModel () EscrowSchema EscrowError (EscrowParams Datum)

  initialState = EscrowModel { _contributions = Map.empty
                             , _targets       = Map.empty
                             , _refundSlot    = 0
                             , _phase         = Initial
                             }

  initialInstances = []

{- START startInstances -}
  startInstances _ (Init s wns) =
    [StartContract (WalletKey w) (escrowParams s wns) | w <- testWallets]
{- END startInstances -}
  startInstances _ _ = []

  instanceWallet (WalletKey w) = w

  instanceContract _ WalletKey{} params = testContract params

{- START nextState -}
  nextState (Init s wns) = do
      phase   .= Running
      targets .= Map.fromList [(w, Ada.adaValueOf (fromInteger n)) | (w,n) <- wns]
      refundSlot .= s                 -- NEW!!!
{- END nextState -}

  nextState a = case a of
    Init s wns -> do
      phase   .= Running
      targets .= Map.fromList [(w, Ada.adaValueOf (fromInteger n)) | (w,n) <- wns]
      refundSlot .= s
    Pay w v -> do
      withdraw w (Ada.adaValueOf $ fromInteger v)
      contributions %= Map.insertWith (<>) w (Ada.adaValueOf $ fromInteger v)
      wait 1
    Redeem w -> do
      targets <- viewContractState targets
      contribs <- viewContractState contributions
      sequence_ [ deposit w v | (w, v) <- Map.toList targets ]
      let leftoverValue = fold contribs <> inv (fold targets)
      deposit w leftoverValue
      contributions .= Map.empty
      wait 1
    Refund w -> do
      v <- viewContractState $ contributions . at w . to fold
      contributions %= Map.delete w
      deposit w v
      wait 1

{- START nextReactiveState -}
  nextReactiveState slot = do
    deadline <- viewContractState refundSlot
    when (slot >= deadline) $ phase .= Refunding
{- END nextReactiveState -}

{- START precondition -}
  precondition s a = case a of
    Init s tgts -> currentPhase == Initial
                && s > 1
                && and [Ada.adaValueOf (fromInteger n) `geq` Ada.toValue minAdaTxOut | (_,n) <- tgts]
    Redeem _    -> currentPhase == Running
                && fold (s ^. contractState . contributions) `geq` fold (s ^. contractState . targets)
    Pay _ v     -> currentPhase == Running
                && Ada.adaValueOf (fromInteger v) `geq` Ada.toValue minAdaTxOut
    Refund w    -> currentPhase == Refunding           -- NEW!!!
                && w `Map.member` (s ^. contractState . contributions)
    where currentPhase = s ^. contractState . phase
{- END precondition -}

  perform h _ _ a = case a of
    Init _ _       -> do
      return ()
    Pay w v        -> do
      Trace.callEndpoint @"pay-escrow" (h $ WalletKey w) (Ada.adaValueOf $ fromInteger v)
      delay 1
    Redeem w       -> do
      Trace.callEndpoint @"redeem-escrow" (h $ WalletKey w) ()
      delay 1
    Refund w       -> do
      Trace.callEndpoint @"refund-escrow" (h $ WalletKey w) ()
      delay 1

{- START arbitraryAction -}
  arbitraryAction s
    | s ^.contractState . phase == Initial
      = Init <$> (Slot . getPositive <$> arbitrary) <*> arbitraryTargets
{- END arbitraryAction -}
    | otherwise
      = frequency $ [ (3, Pay <$> elements testWallets <*> choose (1, 30)) ] ++
                    [ (1, Redeem <$> elements testWallets)
                    | (s ^. contractState . contributions . to fold) `geq` (s ^. contractState . targets . to fold)
                    ]  ++
                    [ (1, Refund <$> elements testWallets) ]
{-
{- START weightedArbitraryAction -}
  arbitraryAction s
    | s ^.contractState . phase == Initial
      = Init <$> (Slot . getPositive <$> scale (*10) arbitrary) <*> arbitraryTargets
{- END weightedArbitraryAction -}
-}

{- START shrinkAction -}
  shrinkAction _ (Init s tgts) = map (Init s) (shrinkList (\(w,n)->(w,)<$>shrink n) tgts)
                              ++ map (`Init` tgts) (map Slot . shrink . getSlot $ s)      -- NEW!!!
{- END shrinkAction -}
  shrinkAction _ (Pay w n)     = [Pay w n' | n' <- shrink n]
  shrinkAction _ _             = []

arbitraryTargets :: Gen [(Wallet,Integer)]
arbitraryTargets = do
  ws <- sublistOf testWallets
  vs <- infiniteListOf $ choose (1,30)
  return $ zip ws vs

testWallets :: [Wallet]
testWallets = [w1, w2, w3, w4, w5]

testContract :: EscrowParams Datum -> Contract () EscrowSchema EscrowError ()
testContract params = selectList [ void $ payEp params
                                 , void $ redeemEp params
                                 , void $ refundEp params
                                 ] >> testContract params


prop_Escrow :: Actions EscrowModel -> Property
prop_Escrow = propRunActions_

{- START escrowParams -}
escrowParams :: Slot -> [(Wallet, Integer)] -> EscrowParams d
escrowParams s tgts =
  EscrowParams
    { escrowTargets  =
        [ payToPaymentPubKeyTarget (mockWalletPaymentPubKeyHash w) (Ada.adaValueOf (fromInteger n))
        | (w,n) <- tgts
        ]
    , escrowDeadline = scSlotZeroTime def + POSIXTime (getSlot s * scSlotLength def)     -- NEW!!!
    }
{- END escrowParams -}


finishEscrow :: DL EscrowModel ()
finishEscrow = do
    anyActions_
    finishingStrategy
    assertModel "Locked funds are not zero" (symIsZero . lockedValue)

{-
{- START oldFinishingStrategy -}
finishingStrategy :: DL EscrowModel ()
finishingStrategy = do
    contribs <- viewContractState contributions
    monitor (tabulate "Refunded wallets" [show . Map.size $ contribs])
    sequence_ [action $ Refund w | w <- testWallets, w `Map.member` contribs]
{- END oldFinishingStrategy -}
-}

{- START finishingStrategy -}
finishingStrategy :: DL EscrowModel ()
finishingStrategy = do
    contribs <- viewContractState contributions
    monitor (tabulate "Refunded wallets" [show . Map.size $ contribs])
    waitUntilDeadline                                                  -- NEW!!!
    sequence_ [action $ Refund w | w <- testWallets, w `Map.member` contribs]
{- END finishingStrategy -}
{-
{- START monitoredFinishingStrategy -}
finishingStrategy :: DL EscrowModel ()
finishingStrategy = do
    contribs <- viewContractState contributions
    monitor (tabulate "Refunded wallets" [show . Map.size $ contribs])
    phase <- viewContractState phase           -- NEW!!!
    monitor $ tabulate "Phase" [show phase]    -- NEW!!!
    waitUntilDeadline
    sequence_ [action $ Refund w | w <- testWallets, w `Map.member` contribs]
{- END monitoredFinishingStrategy -}
-}

walletStrategy :: Wallet -> DL EscrowModel ()
walletStrategy w = do
    contribs <- viewContractState contributions
    when (w `Map.member` contribs) $ do
      --waitUntilDeadline
      action $ Refund w

{- START waitUntilDeadline -}
waitUntilDeadline :: DL EscrowModel ()
waitUntilDeadline = do
    deadline <- viewContractState refundSlot
    slot     <- viewModelState currentSlot
    when (slot < deadline) $ waitUntilDL deadline
{- END waitUntilDeadline -}

noLockProof :: NoLockedFundsProof EscrowModel
noLockProof = defaultNLFP
  { nlfpMainStrategy   = finishingStrategy
  , nlfpWalletStrategy = walletStrategy    }

{- START prop_FinishEscrow -}
prop_FinishEscrow :: Property
prop_FinishEscrow = forAllDL finishEscrow prop_Escrow
{- END prop_FinishEscrow -}

{-
{- START prop_FinishFast -}
prop_FinishFast :: Property
prop_FinishFast = forAllDL finishEscrow $ const True
{- END prop_FinishFast -}
-}

prop_NoLockedFunds :: Property
prop_NoLockedFunds = checkNoLockedFundsProof noLockProof

