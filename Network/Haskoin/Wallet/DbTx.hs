{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeFamilies      #-}
module Network.Haskoin.Wallet.DbTx
( AccTx
, toAccTx
, yamlTx
, importTx
, removeTx
, sendTx
, signWalletTx
, walletBloomFilter
, isTxInWallet
) where

import Control.Applicative ((<$>))
import Control.Monad (forM, forM_, unless, when, liftM, void)
import Control.Monad.Trans (liftIO)
import Control.Exception (throwIO)

import Data.Int (Int64)
import Data.Time (UTCTime, getCurrentTime)
import Data.Word (Word32, Word64)
import Data.List ((\\), nub)
import Data.Maybe (catMaybes, isNothing, isJust, fromJust)
import Data.Either (rights)
import Data.Yaml (Value, object, (.=))
import qualified Data.Map.Strict as M 

import Database.Persist 
    ( PersistStore
    , PersistUnique
    , PersistQuery
    , PersistMonadBackend
    , Entity(..)
    , entityVal
    , entityKey
    , get
    , getBy
    , deleteBy
    , selectList
    , deleteWhere
    , updateWhere
    , update
    , insert_
    , insertUnique
    , replace
    , (=.), (==.), (<-.)
    )

import Network.Haskoin.Wallet.DbAccount
import Network.Haskoin.Wallet.DbAddress
import Network.Haskoin.Wallet.DbCoin
import Network.Haskoin.Wallet.Model
import Network.Haskoin.Wallet.Types
import Network.Haskoin.Wallet.Util

import Network.Haskoin.Transaction
import Network.Haskoin.Script
import Network.Haskoin.Protocol
import Network.Haskoin.Crypto
import Network.Haskoin.Util

data AccTx = AccTx
    { accTxHash          :: TxHash
    , accTxRecipients    :: [Address]
    , accTxValue         :: Int64
    , accTxPartial       :: Bool
    , accTxConfirmations :: Int
    , accTxCreated       :: UTCTime
    } deriving (Read, Eq, Show)

-- TODO: Change this to an instance
yamlTx :: AccTx -> Value
yamlTx accTx = object $ concat
    [ [ "Recipients" .= accTxRecipients accTx
      , "Value" .= accTxValue accTx
      , "Confirmations" .= accTxConfirmations accTx
      ]
    , if accTxPartial accTx then ["Partial" .= True] else []
    ]

toAccTx :: (PersistUnique m, PersistQuery m, PersistMonadBackend m ~ b) 
        => DbAccTxGeneric b -> m AccTx
toAccTx accTx = do
    -- TODO: Keep fromJust?
    tx     <- dbGetTx $ dbAccTxHash accTx
    height <- dbGetBestHeight
    let conf | isNothing $ dbTxConfirmedBy tx = 0
             | otherwise = height - (fromJust $ dbTxConfirmedHeight tx) + 1
    return $ AccTx { accTxHash          = dbAccTxHash accTx
                   , accTxRecipients    = dbAccTxRecipients accTx
                   , accTxValue         = dbAccTxValue accTx
                   , accTxPartial       = dbAccTxPartial accTx
                   , accTxConfirmations = fromIntegral conf
                   , accTxCreated       = dbAccTxCreated accTx
                   }

-- |Import a transaction into the database
importTx :: (PersistQuery m, PersistUnique m) => Tx -> m [AccTx]
importTx tx = do
    existsM  <- getBy $ UniqueTx tid
    isOrphan <- isOrphanTx tx
    -- Do not re-import existing transactions and do not proccess orphans yet
    if isJust existsM || isOrphan then return [] else do
        -- Retrieve the coins we have from the transaction inputs
        eCoins <- liftM catMaybes (mapM (getBy . f) $ map prevOutput $ txIn tx)
        let coins = map entityVal eCoins
        when (isDoubleSpend tid coins) $ liftIO $ throwIO $
            DoubleSpendException "Transaction is double spending coins"
        -- We must remove partial transactions which spend the same coins as us
        forM_ (txToRemove coins) removeTx 
        -- Change status of the coins
        forM_ eCoins $ \(Entity ci _) -> update ci [DbCoinStatus =. status]
        -- Import new coins 
        outCoins <- liftM catMaybes $ 
            (mapM (dbImportCoin tid complete) $ zip (txOut tx) [0..])
        -- Ignore this transaction if it is not ours
        if null $ coins ++ outCoins then return [] else do
            time <- liftIO getCurrentTime
            -- Save the whole transaction
            insertUnique $ DbTx tid tx False Nothing Nothing time
            -- Build transactions that report on individual accounts
            let dbAccTxs = buildAccTx tx coins outCoins (not complete) time
            accTxs <- forM dbAccTxs toAccTx
            -- insert account transactions into database
            forM_ dbAccTxs insert_
            -- Re-import orphans
            liftM (accTxs ++) tryImportOrphans
  where
    tid              = txHash tx
    f (OutPoint h i) = CoinOutPoint h (fromIntegral i)
    complete         = isTxComplete tx
    status           = if complete then Spent tid else Reserved tid

-- Try to re-import all orphan transactions
tryImportOrphans :: (PersistQuery m, PersistUnique m) => m [AccTx]
tryImportOrphans = do
    orphans <- selectList [DbTxOrphan ==. True] []
    res <- forM orphans $ \(Entity _ otx) -> do
        deleteBy $ UniqueTx $ dbTxHash otx
        importTx $ dbTxValue otx
    return $ concat res

-- | Create a new coin for an output if it is ours. If commit is False, it will
-- not write the coin to the database, it will only return it. We need the coin
-- data for partial transactions (for reporting) but we don't want to store
-- them as they can not be spent.
dbImportCoin :: ( PersistQuery m
                , PersistUnique m
                , PersistMonadBackend m ~ b
                )
             => TxHash -> Bool -> (TxOut,Int)
             -> m (Maybe (DbCoinGeneric b))
dbImportCoin tid commit (out, i) = do
    dbAddr <- isMyOutput out
    let script = decodeOutputBS $ scriptOutput out
    if isNothing dbAddr || isLeft script then return Nothing else do
        rdm   <- dbGetRedeem $ fromJust dbAddr
        time  <- liftIO getCurrentTime
        let coin = DbCoin tid i (fromIntegral $ outValue out) 
                                (fromRight script) rdm 
                                (dbAddressValue $ fromJust dbAddr)
                                Unspent
                                (dbAddressAccount $ fromJust dbAddr)
                                time
        when commit $ insert_ coin
        return $ Just coin

-- |Builds a redeem script given an address. Only relevant for addresses
-- linked to multisig accounts. Otherwise it returns Nothing
dbGetRedeem :: (PersistStore m, PersistMonadBackend m ~ b) 
            => DbAddressGeneric b -> m (Maybe ScriptOutput)
dbGetRedeem add = do
    acc <- liftM fromJust (get $ dbAddressAccount add)
    if isMSAcc acc 
        then do
            let key      = dbAccountKey acc
                msKeys   = dbAccountMsKeys acc
                deriv    = fromIntegral $ dbAddressIndex add
                addrKeys = fromJust $ f key msKeys deriv
                pks      = map (xPubKey . getAddrPubKey) addrKeys
                req      = fromJust $ dbAccountMsRequired acc
            return $ Just $ sortMulSig $ PayMulSig pks req
        else return Nothing
  where
    f = if dbAddressInternal add then intMulSigKey else extMulSigKey

-- Returns True if the transaction has an input that belongs to the wallet
-- but we don't have a coin for it yet. We are missing a parent transaction.
-- This function will also add the transaction to the orphan pool if it is
-- orphaned.
isOrphanTx :: PersistUnique m => Tx -> m Bool
isOrphanTx tx = do
    myInputFlags <- mapM isMyInput $ txIn tx
    coinsM       <- mapM (getBy . f) $ map prevOutput $ txIn tx
    let missing = filter g $ zip myInputFlags coinsM
    when (length missing > 0) $ do
        -- Add transaction to the orphan pool
        time <- liftIO getCurrentTime
        _ <- insertUnique $ DbTx tid tx True Nothing Nothing time
        return ()
    return $ length missing > 0
  where
    tid               = txHash tx
    f (OutPoint h i)  = CoinOutPoint h (fromIntegral i)
    g (isMine, coinM) = isJust isMine && isNothing coinM

-- Returns True if the input address is part of the wallet
isMyInput :: ( PersistUnique m
             , PersistMonadBackend m ~ b
             ) 
          => TxIn -> m (Maybe (DbAddressGeneric b))
isMyInput input = do
    let senderE = scriptSender =<< (decodeToEither $ scriptInput input)
        sender  = fromRight senderE
    if isLeft senderE 
        then return Nothing
        else do
            res <- getBy $ UniqueAddress sender
            return $ entityVal <$> res

-- Returns True if the output address is part of the wallet
isMyOutput :: ( PersistUnique m
              , PersistMonadBackend m ~ b
              ) 
           => TxOut -> m (Maybe (DbAddressGeneric b))
isMyOutput out = do
    let recipientE = scriptRecipient =<< (decodeToEither $ scriptOutput out)
        recipient  = fromRight recipientE
    if isLeft recipientE
        then return Nothing 
        else do
            res <- getBy $ UniqueAddress recipient
            return $ entityVal <$> res

-- |A transaction can not be imported if it double spends coins in the wallet.
-- Upstream code needs to remove the conflicting transaction first using
-- dbTxRemove function
-- TODO: We need to consider malleability here
isDoubleSpend :: TxHash -> [DbCoinGeneric b] -> Bool
isDoubleSpend tid coins = any (f . dbCoinStatus) coins
  where
    f (Spent parent) = parent /= tid
    f _              = False

-- When a transaction spends coins previously spent by a partial transaction,
-- we need to remove the partial transactions from the database and try to
-- re-import the transaction. Coins with Reserved status are spent by a partial
-- transaction.
txToRemove :: [DbCoinGeneric b] -> [TxHash]
txToRemove coins = catMaybes $ map (f . dbCoinStatus) coins
  where
    f (Reserved parent) = Just parent
    f _                 = Nothing

-- |Group input and output coins by accounts and create 
-- account-level transaction
buildAccTx :: Tx -> [DbCoinGeneric b] -> [DbCoinGeneric b]
           -> Bool -> UTCTime -> [DbAccTxGeneric b]
buildAccTx tx inCoins outCoins partial time = map build $ M.toList oMap
  where
    -- We build a map of accounts to ([input coins], [output coins])
    iMap = foldr (f (\(i,o) x -> (x:i,o))) M.empty inCoins
    oMap = foldr (f (\(i,o) x -> (i,x:o))) iMap outCoins
    f g coin accMap = case M.lookup (dbCoinAccount coin) accMap of
        Just tuple -> M.insert (dbCoinAccount coin) (g tuple coin) accMap
        Nothing    -> M.insert (dbCoinAccount coin) (g ([],[]) coin) accMap
    allRecip = rights $ map toAddr $ txOut tx
    toAddr   = (scriptRecipient =<<) . decodeToEither . scriptOutput
    sumVal   = sum . (map dbCoinValue)
    build (ai,(i,o)) = DbAccTx (txHash tx) recips total ai partial time
      where
        total = (fromIntegral $ sumVal o) - (fromIntegral $ sumVal i)
        addrs = map dbCoinAddress o
        recips | null addrs = allRecip
               | total < 0  = allRecip \\ addrs -- remove the change
               | otherwise  = addrs

-- |Remove a transaction from the database and all parent transaction
removeTx :: PersistQuery m => TxHash -> m [TxHash]
removeTx tid = do
    -- Find all parents of this transaction
    -- Partial transactions should not have any coins. Won't check for it
    coins <- selectList [ DbCoinHash ==. tid ] []
    let parents = nub $ catStatus $ map (dbCoinStatus . entityVal) coins
    -- Recursively remove parents
    pids <- forM parents removeTx
    -- Delete output coins generated from this transaction
    deleteWhere [ DbCoinHash ==. tid ]
    -- Delete account transactions
    deleteWhere [ DbAccTxHash ==. tid ]
    -- Delete transaction
    deleteWhere [ DbTxHash ==. tid ]
    -- Unspend input coins that were previously spent by this transaction
    updateWhere [ DbCoinStatus <-. [Spent tid, Reserved tid] ]
                [ DbCoinStatus =. Unspent ]
    return $ tid:(concat pids)

-- |Build and sign a transactoin given a list of recipients
sendTx :: (PersistUnique m, PersistQuery m)
         => AccountName -> [(String,Word64)] -> Word64 -> m (Tx, Bool)
sendTx name strDests fee = do
    (coins,recips) <- dbSendSolution name strDests fee
    dbSendCoins coins recips (SigAll False)

-- |Given a list of recipients and a fee, finds a valid combination of coins
dbSendSolution :: (PersistUnique m, PersistQuery m)
               => AccountName -> [(String,Word64)] -> Word64
               -> m ([Coin],[(Address,Word64)])
dbSendSolution name strDests fee = do
    unless (all isJust decodeDest) $ liftIO $ throwIO $
        InvalidAddressException "Invalid addresses"
    (Entity ai acc) <- dbGetAccount name
    unspent <- liftM (map toCoin) $ dbCoins ai
    let msParam = ( fromJust $ dbAccountMsRequired acc
                  , fromJust $ dbAccountMsTotal acc
                  )
        resE | isMSAcc acc = chooseMSCoins tot fee msParam unspent
             | otherwise   = chooseCoins tot fee unspent
        (coins, change)    = fromRight resE
    when (isLeft resE) $ liftIO $ throwIO $
        CoinSelectionException $ fromLeft resE
    recips <- if change < 5000 then return dests else do
        cAddr <- dbGenIntAddrs name 1
        -- TODO: Change must be randomly placed
        return $ dests ++ [(dbAddressValue $ head cAddr,change)]
    return (coins,recips)
  where
    decodeDest = map f strDests
    f (str,v)  = (\x -> (x,v)) <$> base58ToAddr str
    dests      = map fromJust decodeDest
    tot        = sum $ map snd dests
    
-- | Build and sign a transaction by providing coins and recipients
dbSendCoins :: PersistUnique m
            => [Coin] -> [(Address,Word64)] -> SigHash
            -> m (Tx, Bool)
dbSendCoins coins recipients sh = do
    let txE = buildAddrTx (map coinOutPoint coins) $ map f recipients
        tx  = fromRight txE
    when (isLeft txE) $ liftIO $ throwIO $
        TransactionBuildingException $ fromLeft txE
    ys <- mapM (dbGetSigData sh) coins
    let sigTx = detSignTx tx (map fst ys) (map snd ys)
    when (isBroken sigTx) $ liftIO $ throwIO $
        TransactionSigningException $ runBroken sigTx
    return (runBuild sigTx, isComplete sigTx)
  where
    f (a,v) = (addrToBase58 a, v)

signWalletTx :: PersistUnique m
         => AccountName -> Tx -> SigHash -> m (Tx, Bool)
signWalletTx name tx sh = do
    (Entity ai _) <- dbGetAccount name
    coins <- liftM catMaybes (mapM (getBy . f) $ map prevOutput $ txIn tx)
    -- Filter coins for this account only
    let accCoinsDB = filter ((== ai) . dbCoinAccount . entityVal) coins
        accCoins   = map (toCoin . entityVal) accCoinsDB
    ys <- forM accCoins (dbGetSigData sh)
    let sigTx = detSignTx tx (map fst ys) (map snd ys)
    when (isBroken sigTx) $ liftIO $ throwIO $
        TransactionSigningException $ runBroken sigTx
    return (runBuild sigTx, isComplete sigTx)
  where
    f (OutPoint h i) = CoinOutPoint h (fromIntegral i)

-- |Given a coin, retrieves the necessary data to sign a transaction
dbGetSigData :: PersistUnique m
             => SigHash -> Coin -> m (SigInput,PrvKey)
dbGetSigData sh coin = do
    (Entity _ w) <- dbGetWallet "main"
    let a = fromRight $ scriptRecipient out
    (Entity _ add) <- dbGetAddr $ addrToBase58 a
    acc  <- liftM fromJust (get $ dbAddressAccount add)
    let master = dbWalletMaster w
        deriv  = fromIntegral $ dbAccountIndex acc
        accKey = fromJust $ accPrvKey master deriv
        g      = if dbAddressInternal add then intPrvKey else extPrvKey
        sigKey = fromJust $ g accKey $ fromIntegral $ dbAddressIndex add
    return (sigi, xPrvKey $ getAddrPrvKey sigKey)
  where
    out    = decode' $ scriptOutput $ coinTxOut coin
    rdm    = coinRedeem coin
    sigi | isJust rdm = SigInputSH out (coinOutPoint coin) (fromJust rdm) sh
         | otherwise  = SigInput out (coinOutPoint coin) sh

-- |Produces a bloom filter containing all the addresses in this wallet. This
-- includes internal, external and look-ahead addresses. The bloom filter can
-- be set on a peer connection to filter the transactions received by that
-- peer.
walletBloomFilter :: PersistQuery m => m BloomFilter
walletBloomFilter = do
    addrs <- selectList [] []
    -- TODO: Choose a random nonce for the bloom filter
    let bloom  = bloomCreate (length addrs * 2) 0.001 0 BloomUpdateP2PubKeyOnly
        bloom' = foldl f bloom $ map (dbAddressValue . entityVal) addrs
        f b a  = bloomInsert b $ encode' $ getAddrHash a
    return bloom'

isTxInWallet :: PersistUnique m => TxHash -> m Bool
isTxInWallet tid = liftM isJust $ getBy $ UniqueTx tid

