{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeFamilies      #-}
module Network.Haskoin.Wallet.Store.DbTx
( dbImportTx
, dbRemoveTx
, dbSendTx
, dbSendSolution
, dbSendCoins
, dbSignTx
, yamlTx
, RawTxOutPoints(..)
, RawTxDests(..)
, RawSigInput(..)
, RawPrvKey(..)
) where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Either

import Data.Time
import Data.Word
import Data.List
import Data.Maybe
import Data.Either
import Data.Yaml
import qualified Data.Vector as V (toList)
import qualified Data.HashMap.Strict as H (toList)
import qualified Data.Aeson as Json
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.ByteString as BS
import qualified Data.Conduit as C

import Database.Persist
import Database.Persist.Sqlite
import Database.Persist.TH

import Network.Haskoin.Wallet.Keys
import Network.Haskoin.Wallet.Manager
import Network.Haskoin.Wallet.TxBuilder
import Network.Haskoin.Wallet.Store.DbAccount
import Network.Haskoin.Wallet.Store.DbAddress
import Network.Haskoin.Wallet.Store.DbCoin
import Network.Haskoin.Wallet.Store.Util
import Network.Haskoin.Script
import Network.Haskoin.Protocol
import Network.Haskoin.Crypto
import Network.Haskoin.Util
import Network.Haskoin.Util.BuildMonad

yamlTx :: DbTxGeneric b -> Value
yamlTx tx = object $ concat
    [ [ "Recipients" .= dbTxRecipients tx
      , "Value" .= dbTxValue tx
      ]
    , if dbTxOrphan tx then ["Orphan" .= True] else []
    , if dbTxPartial tx then ["Partial" .= True] else []
    ]

-- |Remove a transaction from the database and any parent transaction
dbRemoveTx :: ( PersistStore m, PersistQuery m, PersistUnique m
              , PersistMonadBackend m ~ b, b ~ SqlBackend
              )
           => String -> EitherT String m [String]
dbRemoveTx txid = do
    -- Find all parents of this transaction
    -- Partial transactions should not have any coins. Won't check for it
    coins <- selectList [ DbCoinTxid ==. txid ] []
    let parents = nub $ catStatus $ map (dbCoinStatus . entityVal) coins
    -- Recursively remove parents
    pids <- forM parents dbRemoveTx
    -- Delete output coins generated from this transaction
    deleteWhere [ DbCoinTxid ==. txid ]
    -- Delete account transactions
    deleteWhere [ DbTxTxid ==. txid ]
    -- Delete transaction blob
    deleteWhere [ DbTxBlobTxid ==. txid ]
    -- Delete orphaned input coins spent by this transaction
    deleteWhere [ DbCoinOrphan ==. True
                , DbCoinStatus <-. [Spent txid, Reserved txid]
                ]
    -- Unspend input coins that were previously spent by this transaction
    updateWhere [ DbCoinStatus <-. [Spent txid, Reserved txid] ]
                [ DbCoinStatus =. Unspent ]
    return $ txid:(concat pids)
          
-- |Import a transaction into the database
dbImportTx :: ( PersistStore m, PersistQuery m, PersistUnique m
              , PersistMonadBackend m ~ b, b ~ SqlBackend
              ) 
           => Tx -> EitherT String m [DbTxGeneric b]
dbImportTx tx = do
    coinsM <- mapM (getBy . f) $ map prevOutput $ txIn tx
    let inCoins = catMaybes coinsM
        -- Unspent coins in the wallet related to this transaction
        unspent = filter ((== Unspent) . dbCoinStatus . entityVal) inCoins
        -- OutPoints from this transaction with no associated coins
        unknown = map snd $ filter (isNothing . fst) $ zip coinsM $ txIn tx
    -- Fail if an input is spent by a transaction which is not this one
    unless (isImportValid id $ map entityVal inCoins) $ left
        "dbImportTx: Double spend detected. Import failed"
    let toRemove = txToRemove $ map entityVal inCoins
    if length toRemove > 0
        then do
            -- Partial transactions need to be removed before trying to re-import
            mapM dbRemoveTx toRemove
            dbImportTx tx
        else do
            time <- liftIO getCurrentTime
            -- Change status of all the unspent coins
            forM unspent $ \(Entity ci _) -> update ci [DbCoinStatus =. status]
            -- Insert orphaned coins
            orphans <- catMaybes <$> mapM (dbImportOrphan status) unknown
            -- Import new coins and update existing coins
            outCoins <- catMaybes <$> 
                (mapM (dbImportCoin id complete) $ zip (txOut tx) [0..])
            let accTxs = buildAccTx tx ((map entityVal inCoins) ++ orphans)
                            outCoins (not complete) time
            -- Insert transaction blob. Ignore if already exists
            insertUnique $ DbTxBlob id (encode' tx) time
            -- insert account transactions into database, rewriting if they exist
            forM accTxs $ \accTx -> do
                prev <- getBy $ UniqueTx (dbTxTxid accTx) (dbTxAccount accTx)
                if isNothing prev 
                    then insert_ accTx  
                    else replace (entityKey $ fromJust prev) accTx
            -- Re-import parent transactions (transactions spending this one)
            if complete
                then do
                    let ids = nub $ catStatus $ map dbCoinStatus outCoins
                    blobs <- mapM dbGetTxBlob ids
                    reImported <- forM blobs $ (dbImportTx =<<) . dec
                    return $ accTxs ++ (concat reImported)
                else return accTxs
  where
    id               = encodeTxid $ txid tx
    f (OutPoint h i) = CoinOutPoint (encodeTxid h) (fromIntegral i)
    complete         = isTxComplete tx
    status           = if complete then Spent id else Reserved id
    dec              = liftEither . decodeToEither . dbTxBlobValue . entityVal

-- |A transaction can not be imported if it double spends coins in the wallet.
-- Upstream code needs to remove the conflicting transaction first using
-- dbTxRemove function
isImportValid :: String -> [DbCoinGeneric b] -> Bool
isImportValid id coins = all (f . dbCoinStatus) coins
  where
    f (Spent parent) = parent == id
    f _              = True

-- When a transaction spends coins previously spent by a partial transaction,
-- we need to remove the partial transactions from the database and try to
-- re-import the transaction. Coins with Reserved status are spent by a partial
-- transaction.
txToRemove :: [DbCoinGeneric b] -> [String]
txToRemove coins = catMaybes $ map (f . dbCoinStatus) coins
  where
    f (Reserved parent) = Just parent
    f _                 = Nothing

-- |Group input and output coins by accounts and create 
-- account-level transaction
buildAccTx :: Tx -> [DbCoinGeneric b] -> [DbCoinGeneric b]
           -> Bool -> UTCTime -> [DbTxGeneric b]
buildAccTx tx inCoins outCoins partial time = map build $ M.toList oMap
  where
    iMap = foldr (f (\(i,o) x -> (x:i,o))) M.empty inCoins
    oMap = foldr (f (\(i,o) x -> (i,x:o))) iMap outCoins
    f g coin accMap = case M.lookup (dbCoinAccount coin) accMap of
        Just tuple -> M.insert (dbCoinAccount coin) (g tuple coin) accMap
        Nothing    -> M.insert (dbCoinAccount coin) (g ([],[]) coin) accMap
    allRecip = rights $ map toAddr $ txOut tx
    toAddr   = (addrToBase58 <$>) . scriptRecipient . scriptOutput
    sumVal   = sum . (map dbCoinValue)
    build (ai,(i,o)) = 
        DbTx (encodeTxid $ txid tx) recip total ai orphan partial time
      where
        orphan = or $ map dbCoinOrphan i
        total | orphan    = 0
              | otherwise = sumVal o - sumVal i
        addrs = map dbCoinAddress o
        recip | null addrs = allRecip
              | orphan     = allRecip \\ addrs -- assume this is an outgoing tx
              | total < 0  = allRecip \\ addrs -- remove the change
              | otherwise  = addrs

-- |Create an orphaned coin if the input spends from an address in the wallet
-- but the coin doesn't exist in the wallet. This allows out-of-order tx import
dbImportOrphan :: ( PersistStore m, PersistQuery m, PersistUnique m
                  , PersistMonadBackend m ~ b, b ~ SqlBackend
                  ) 
               => CoinStatus -> TxIn 
               -> EitherT String m (Maybe (DbCoinGeneric b))
dbImportOrphan status (TxIn op@(OutPoint h i) s _)
    | isLeft a  = return Nothing
    | otherwise = getBy (UniqueAddress b58) >>= \addrM -> case addrM of
        Nothing              -> return Nothing
        Just (Entity _ addr) -> do
            time <- liftIO $ getCurrentTime
            rdm  <- dbGetRedeem addr
            let coin = build rdm addr time
            insert_ coin >> return (Just coin)
  where
    a   = scriptSender s
    b58 = addrToBase58 $ fromRight a
    build rdm addr time = 
        DbCoin (encodeTxid h) (fromIntegral i) 0 "" rdm b58 status
               (dbAddressAccount addr) True time

-- |Create a new coin for an output if it sends coins to an 
-- address in the wallet. Does not actually write anything to the database
-- if commit is False. This is for correctly reporting on partial transactions
-- without creating coins in the database from a partial transaction
dbImportCoin :: ( PersistStore m, PersistQuery m, PersistUnique m
                , PersistMonadBackend m ~ b, b ~ SqlBackend
                )
             => String -> Bool -> (TxOut,Int) 
             -> EitherT String m (Maybe (DbCoinGeneric b))
dbImportCoin txid commit ((TxOut v s), index) 
    | isLeft a  = return Nothing
    | otherwise = getBy (UniqueAddress b58) >>= \addrM -> case addrM of
        Nothing              -> return Nothing
        Just (Entity _ addr) -> do
            time  <- liftIO getCurrentTime
            coinM <- getBy $ CoinOutPoint txid index
            case coinM of
                Just (Entity ci coin) -> do
                    -- Update existing coin with up to date information
                    let newCoin = coin{ dbCoinOrphan  = False
                                      , dbCoinValue   = (fromIntegral v)
                                      , dbCoinScript  = scp
                                      , dbCoinCreated = time
                                      }
                    when commit $ replace ci newCoin
                    return $ Just newCoin
                Nothing -> do
                    rdm <- dbGetRedeem addr
                    let coin = build rdm addr time
                    when commit $ insert_ coin
                    dbAdjustGap addr -- Adjust address gap
                    return $ Just coin
  where
    a   = scriptRecipient s
    b58 = addrToBase58 $ fromRight a
    scp = bsToHex $ encodeScriptOps s
    build rdm addr time = 
        DbCoin  txid index (fromIntegral v) scp rdm b58 Unspent
               (dbAddressAccount addr) False time
    
-- |Builds a redeem script given an address. Only relevant for addresses
-- linked to multisig accounts. Otherwise it returns Nothing
dbGetRedeem :: ( PersistStore m, PersistQuery m, PersistUnique m
               , PersistMonadBackend m ~ b, b ~ SqlBackend
               ) 
            => DbAddressGeneric b -> EitherT String m (Maybe String)
dbGetRedeem addr = do
    acc <- liftMaybe accErr =<< (get $ dbAddressAccount addr)
    rdm <- if isMSAcc acc 
        then Just <$> liftMaybe rdmErr (getRdm acc)
        else return Nothing
    return $ bsToHex . encodeScriptOps . encodeOutput <$> rdm
  where
    getRdm acc = do
        key      <- loadPubAcc =<< (xPubImport $ dbAccountKey acc)
        msKeys   <- mapM xPubImport $ dbAccountMsKeys acc
        addrKeys <- f key msKeys $ fromIntegral $ dbAddressIndex addr
        let pks = map (xPubKey . runAddrPubKey) addrKeys
        sortMulSig . (PayMulSig pks) <$> dbAccountMsRequired acc
      where
        f = if dbAddressInternal addr then intMulSigKey else extMulSigKey
    accErr = "dbImportOut: Invalid address account"
    rdmErr = "dbGetRedeem: Could not generate redeem script"

-- |Build and sign a transactoin given a list of recipients
dbSendTx :: ( PersistStore m, PersistQuery m, PersistUnique m
            , PersistMonadBackend m ~ SqlBackend
            )
         => AccountName -> [(String,Word64)] -> Word64
         -> EitherT String m (Tx, Bool)
dbSendTx name dests fee = do
    (coins,recip) <- dbSendSolution name dests fee
    dbSendCoins coins recip (SigAll False)

-- |Given a list of recipients and a fee, finds a valid combination of coins
dbSendSolution :: ( PersistStore m, PersistQuery m, PersistUnique m
                  , PersistMonadBackend m ~ SqlBackend
                  )
               => AccountName -> [(String,Word64)] -> Word64
               -> EitherT String m ([Coin],[(String,Word64)])
dbSendSolution name dests fee = do
    (Entity ai acc) <- dbGetAcc name
    unspent <- liftEither . (mapM toCoin) =<< dbCoins ai
    (coins,change) <- liftEither $ if isMSAcc acc
        then let msParam = ( fromJust $ dbAccountMsRequired acc
                           , fromJust $ dbAccountMsTotal acc
                           )
             in chooseMSCoins tot fee msParam unspent
        else chooseCoins tot fee unspent
    recip <- if change < 5000 then return dests else do
        cAddr <- dbGenIntAddrs name 1
        return $ dests ++ [(dbAddressBase58 $ head cAddr,change)]
    return (coins,recip)
  where
    tot = sum $ map snd dests
    
-- |Build and sign a transaction by providing coins and recipients
dbSendCoins :: (PersistStore m, PersistQuery m, PersistUnique m)
            => [Coin] -> [(String,Word64)] -> SigHash
            -> EitherT String m (Tx, Bool)
dbSendCoins coins recipients sh = do
    tx <- liftEither $ buildAddrTx (map coinOutPoint coins) recipients
    ys <- mapM (dbGetSigData sh) coins
    let sigTx = detSignTx tx (map fst ys) (map snd ys)
    bsTx <- liftEither $ buildToEither sigTx
    return (bsTx, isComplete sigTx)

dbSignTx :: (PersistStore m, PersistQuery m, PersistUnique m)
         => AccountName -> Tx -> SigHash -> EitherT String m (Tx, Bool)
dbSignTx name tx sh = do
    (Entity ai acc) <- dbGetAcc name
    coins <- catMaybes <$> (mapM (getBy . f) $ map prevOutput $ txIn tx)
    -- Filter coins for this account only
    let accCoins = filter ((== ai) . dbCoinAccount . entityVal) coins
    ys <- forM accCoins g
    let sigTx = detSignTx tx (map fst ys) (map snd ys)
    bsTx <- liftEither $ buildToEither sigTx
    return (bsTx, isComplete sigTx)
  where
    f (OutPoint h i) = CoinOutPoint (encodeTxid h) (fromIntegral i)
    g = ((dbGetSigData sh) =<<) . liftEither . toCoin . entityVal

-- |Given a coin, retrieves the necessary data to sign a transaction
dbGetSigData :: (PersistStore m, PersistUnique m, PersistQuery m)
             => SigHash -> Coin -> EitherT String m (SigInput,PrvKey)
dbGetSigData sh coin = do
    (Entity _ w) <- dbGetWallet "main"
    a   <- liftEither $ scriptRecipient out
    (Entity _ addr) <- dbGetAddr $ addrToBase58 a
    acc  <- liftMaybe accErr =<< get (dbAddressAccount addr)
    mst <- liftMaybe mstErr $ loadMasterKey =<< xPrvImport (dbWalletMaster w)
    aKey <- liftMaybe prvErr $ accPrvKey mst $ fromIntegral $ dbAccountIndex acc
    let g = if dbAddressInternal addr then intPrvKey else extPrvKey
    sigKey <- liftMaybe addErr $ g aKey $ fromIntegral $ dbAddressIndex addr
    return (sigi, xPrvKey $ runAddrPrvKey sigKey)
  where
    out    = scriptOutput $ coinTxOut coin
    rdm    = coinRedeem coin
    sigi | isJust rdm = SigInputSH out (coinOutPoint coin) (fromJust rdm) sh
         | otherwise  = SigInput out (coinOutPoint coin) sh
    mstErr = "dbGetSigData: Could not load master key"
    accErr = "dbGetSigData: Could not load address account"
    prvErr = "dbGetSigData: Invalid account derivation index"
    addErr = "dbGetSigData: Invalid address derivation index"

data RawTxOutPoints = RawTxOutPoints [OutPoint] 
    deriving (Eq, Show)

data RawTxDests = RawTxDests [(String,Word64)]
    deriving (Eq, Show)

instance Json.FromJSON RawTxOutPoints where
    parseJSON = Json.withArray "Expected: Array" $ \arr -> do
        RawTxOutPoints <$> (mapM f $ V.toList arr)
      where
        f = Json.withObject "Expected: Object" $ \obj -> do
            txid <- obj .: T.pack "txid" :: Parser String
            vout <- obj .: T.pack "vout" :: Parser Word32
            let i = maybeToEither "Failed to decode txid" (decodeTxid txid)
                o = OutPoint <$> i <*> (return vout)
            either (const mzero) return o

instance Json.FromJSON RawTxDests where
    parseJSON = Json.withObject "Expected: Object" $ \obj ->
        RawTxDests <$> (mapM f $ H.toList obj)
      where
        f (addr,v) = do
            amnt <- parseJSON v :: Parser Word64
            return (T.unpack addr, amnt)

data RawSigInput = RawSigInput [(SigHash -> SigInput)]

data RawPrvKey = RawPrvKey [PrvKey]
    deriving (Eq, Show)

instance Json.FromJSON RawSigInput where
    parseJSON = Json.withArray "Expected: Array" $ \arr -> do
        RawSigInput <$> (mapM f $ V.toList arr)
      where
        f = Json.withObject "Expected: Object" $ \obj -> do
            txid <- obj .: T.pack "txid" :: Parser String
            vout <- obj .: T.pack "vout" :: Parser Word32
            scp  <- obj .: T.pack "scriptPubKey" :: Parser String
            rdm  <- obj .:? T.pack "scriptRedeem" :: Parser (Maybe String)
            let s = decodeScriptOps =<< maybeToEither "Hex parsing failed" 
                        (hexToBS scp)
                i = maybeToEither "Failed to decode txid" (decodeTxid txid)
                o = OutPoint <$> i <*> (return vout)
                r = decodeScriptOps =<< maybeToEither "Hex parsing failed" 
                        (hexToBS $ fromJust rdm)
                res | isJust rdm = SigInputSH <$> s <*> o <*> r
                    | otherwise  = SigInput <$> s <*> o
            either (const mzero) return res

instance Json.FromJSON RawPrvKey where
    parseJSON = Json.withArray "Expected: Array" $ \arr ->
        RawPrvKey <$> (mapM f $ V.toList arr)
      where
        f v = do
            str <- parseJSON v :: Parser String  
            maybe mzero return $ fromWIF str

