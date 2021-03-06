{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE TypeFamilies      #-}
module Network.Haskoin.Wallet.Account 
( getAccount
, getAccountEntity
, getWalletEntity
, newAccount
, newMSAccount
, newReadAccount
, newReadMSAccount
, addAccountKeys
, accountList
, accountPrvKey
, isMSAccount
, isReadAccount
) where

import Control.Monad (liftM, unless, when)
import Control.Monad.Reader (ReaderT)
import Control.Exception (throwIO)
import Control.Monad.Trans (MonadIO, liftIO)

import Data.List (nub)
import Data.Maybe (fromJust, isJust, isNothing, catMaybes)
import Data.Time (getCurrentTime)

import Database.Persist
    ( PersistUnique
    , PersistQuery
    , Entity(..)
    , getBy
    , replace
    , insert_
    , update
    , selectList
    , entityVal
    , (=.)
    , SelectOpt( Asc )
    )

import Network.Haskoin.Crypto
import Network.Haskoin.Wallet.Root
import Network.Haskoin.Wallet.Model
import Network.Haskoin.Wallet.Types

-- | Get an account by name
getAccount :: (MonadIO m, PersistQuery b, PersistUnique b)
           => AccountName   -- ^ Account name
           -> ReaderT b m Account     -- ^ Account
getAccount name = liftM (dbAccountValue . entityVal) $ getAccountEntity name

getAccountEntity :: (MonadIO m, PersistUnique b)
                 => AccountName -> ReaderT b m (Entity (DbAccountGeneric b))
getAccountEntity name = do
    entM <- getBy $ UniqueAccName name
    case entM of
        Just ent -> return ent
        Nothing   -> liftIO $ throwIO $ WalletException $ 
            unwords ["Account", name, "does not exist"]

-- | Returns a list of all accounts in the wallet.
accountList :: (MonadIO m, PersistQuery b)
            => ReaderT b m [Account] -- ^ List of accounts in the wallet
accountList = 
    liftM (map f) $ selectList [] [Asc DbAccountCreated]
  where
    f = dbAccountValue . entityVal
                  
-- | Create a new account from an account name. Accounts are identified by
-- their name and they must be unique. After creating a new account, you may
-- want to call 'setLookAhead'.
newAccount :: (MonadIO m, PersistUnique b, PersistQuery b) 
             => String     -- ^ Wallet name 
             -> String     -- ^ Account name
             -> ReaderT b m Account -- ^ Returns the new account information
newAccount wname name = do
    prevAcc <- getBy $ UniqueAccName name
    when (isJust prevAcc) $ liftIO $ throwIO $ WalletException $
        unwords [ "Account", name, "already exists" ]
    time <- liftIO getCurrentTime
    (Entity wk w) <- getWalletEntity wname
    let deriv = maybe 0 (+1) $ dbWalletAccIndex w
        (k,i) = head $ accPubKeys (walletMasterKey $ dbWalletValue w) deriv
        acc   = RegularAccount name wname i k
    insert_ $ DbAccount name acc 0 (Just wk) time
    update wk [DbWalletAccIndex =. Just i]
    return acc

-- | Create a new multisignature account. The thirdparty keys can be provided
-- now or later using the 'cmdAddKeys' command. The number of thirdparty keys
-- can not exceed n-1 as your own account key will be used as well in the
-- multisignature scheme. If less than n-1 keys are provided, the account will
-- be in a pending state and no addresses can be generated.
--
-- In order to prevent usage mistakes, you can not create a multisignature 
-- account with other keys from your own wallet. Once the account is set up
-- with all the keys, you may want to call 'setLookAhead'.
newMSAccount :: (MonadIO m, PersistUnique b, PersistQuery b)
             => String       -- ^ Wallet name
             -> String       -- ^ Account name
             -> Int          -- ^ Required number of keys (m in m of n)
             -> Int          -- ^ Total number of keys (n in m of n)
             -> [XPubKey]    -- ^ Thirdparty public keys
             -> ReaderT b m Account -- ^ Returns the new account information
newMSAccount wname name m n mskeys = do
    prevAcc <- getBy $ UniqueAccName name
    when (isJust prevAcc) $ liftIO $ throwIO $ WalletException $
        unwords [ "Account", name, "already exists" ]
    let keys = nub mskeys
    time <- liftIO getCurrentTime
    unless (n >= 1 && n <= 16 && m >= 1 && m <= n) $ liftIO $ throwIO $ 
        WalletException "Invalid multisig parameters"
    unless (length keys < n) $ liftIO $ throwIO $
        WalletException "Too many keys"
    checkOwnKeys keys
    (Entity wk w) <- getWalletEntity wname
    let deriv = maybe 0 (+1) $ dbWalletAccIndex w
        (k,i) = head $ accPubKeys (walletMasterKey $ dbWalletValue w) deriv
        acc   = MultisigAccount name wname i m n $ getAccPubKey k:keys
    insert_ $ DbAccount name acc 0 (Just wk) time
    update wk [DbWalletAccIndex =. Just i]
    return acc

-- | Create a new read-only account.
newReadAccount :: (MonadIO m, PersistUnique b, PersistQuery b)
               => String    -- ^ Account name
               -> XPubKey   -- ^ Read-only key
               -> ReaderT b m Account -- ^ New account
newReadAccount name key = do
    prevAcc <- getBy $ UniqueAccName name
    when (isJust prevAcc) $ liftIO $ throwIO $ WalletException $
        unwords [ "Account", name, "already exists" ]
    checkOwnKeys [key]
    let accKeyM = loadPubAcc key
    -- TODO: Should we relax the rules for account keys?
    when (isNothing accKeyM) $ liftIO $ throwIO $ WalletException $
        "Invalid account key provided"
    time <- liftIO getCurrentTime
    let acc = ReadAccount name $ fromJust accKeyM
    insert_ $ DbAccount name acc 0 Nothing time
    return acc

newReadMSAccount :: (MonadIO m, PersistUnique b, PersistQuery b)
                 => String       -- ^ Account name
                 -> Int          -- ^ Required number of keys (m in m of n)
                 -> Int          -- ^ Total number of keys (n in m of n)
                 -> [XPubKey]    -- ^ Keys
                 -> ReaderT b m Account -- ^ Returns the new account information
newReadMSAccount name m n mskeys = do
    prevAcc <- getBy $ UniqueAccName name
    when (isJust prevAcc) $ liftIO $ throwIO $ WalletException $
        unwords [ "Account", name, "already exists" ]
    let keys = nub mskeys
    time <- liftIO getCurrentTime
    unless (n >= 1 && n <= 16 && m >= 1 && m <= n) $ liftIO $ throwIO $ 
        WalletException "Invalid multisig parameters"
    unless (length keys <= n) $ liftIO $ throwIO $
        WalletException "Too many keys"
    checkOwnKeys keys
    let acc   = ReadMSAccount name m n keys
    insert_ $ DbAccount name acc 0 Nothing time
    return acc

-- | Add new thirdparty keys to a multisignature account. This function can
-- fail if the multisignature account already has all required keys. In order
-- to prevent usage mistakes, adding a key from your own wallet will fail.
addAccountKeys :: (MonadIO m, PersistUnique b, PersistQuery b)
               => AccountName -- ^ Account name
               -> [XPubKey]   -- ^ Thirdparty public keys to add
               -> ReaderT b m Account   -- ^ Returns the account information
addAccountKeys name keys 
    | null keys = liftIO $ throwIO $
         WalletException "Thirdparty key list can not be empty"
    | otherwise = do
        (Entity ai dbacc) <- getAccountEntity name
        unless (isMSAccount $ dbAccountValue dbacc) $ liftIO $ throwIO $ 
            WalletException "Can only add keys to a multisig account"
        checkOwnKeys keys
        let acc      = dbAccountValue dbacc
            prevKeys = accountKeys acc
        when (length prevKeys == accountTotal acc) $ 
            liftIO $ throwIO $ WalletException 
                "The account is complete and no further keys can be added"
        let newKeys = nub $ prevKeys ++ keys
            newAcc  = acc { accountKeys = newKeys }
        when (length newKeys > accountTotal acc) $
            liftIO $ throwIO $ WalletException
                "Adding too many keys to the account"
        replace ai dbacc{ dbAccountValue = newAcc }
        return newAcc

checkOwnKeys :: (MonadIO m, PersistQuery b) => [XPubKey] -> ReaderT b m ()
checkOwnKeys keys = do
    accs <- accountList
    let myKeysM = map f accs
        myKeys  = catMaybes myKeysM
        overlap = filter (`elem` myKeys) $ map xPubKey keys
    unless (null overlap) $ liftIO $ throwIO $ WalletException 
        "Can not add your own keys to an account"
  where
    f acc | isReadAccount acc = Nothing
          | isMSAccount acc   = Just $ xPubKey $ head $ accountKeys acc
          | otherwise         = Just $ xPubKey $ getAccPubKey $ accountKey acc

-- | Returns information on extended public and private keys of an account.
-- For a multisignature account, thirdparty keys are also returned.
accountPrvKey :: (MonadIO m, PersistUnique b, PersistQuery b)
              => AccountName -- ^ Account name
              -> ReaderT b m AccPrvKey -- ^ Account private key
accountPrvKey name = do
    account <- getAccount name
    wallet  <- getWallet $ accountWallet account
    let master = walletMasterKey wallet
        deriv  = accountIndex account
    return $ fromJust $ accPrvKey master deriv

{- Helpers -}

isMSAccount :: Account -> Bool
isMSAccount acc = case acc of
    MultisigAccount _ _ _ _ _ _ -> True
    ReadMSAccount _ _ _ _       -> True
    _                           -> False

isReadAccount :: Account -> Bool
isReadAccount acc = case acc of
    ReadAccount _ _       -> True
    ReadMSAccount _ _ _ _ -> True
    _                     -> False

