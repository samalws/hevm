{-# LANGUAGE StrictData #-}
{-# Language GADTs #-}
{-# Language DataKinds #-}

module EVM.Fetch where

import Prelude hiding (Word)

import EVM.ABI
import EVM.Types    (Addr, W256, hexText, Expr(Lit), Expr(..), Prop(..), (.&&), (./=))
import EVM.SMT
import EVM.Solvers
import EVM          (EVM, Contract, Block, initialContract, nonce, balance, external)
import qualified EVM.FeeSchedule as FeeSchedule

import qualified EVM

import Control.Lens hiding ((.=))
import Control.Monad.Trans.Maybe
import Data.Aeson hiding (Error)
import Data.Aeson.Lens
import qualified Data.ByteString as BS
import Data.Text (Text, unpack, pack)
import Data.Maybe (fromMaybe)
import Data.List (foldl')
import qualified Data.Text as T

import qualified Data.Vector as RegularVector
import Network.Wreq
import Network.Wreq.Session (Session)
import System.Process

import qualified Network.Wreq.Session as Session
import Numeric.Natural (Natural)

-- | Abstract representation of an RPC fetch request
data RpcQuery a where
  QueryCode    :: Addr         -> RpcQuery BS.ByteString
  QueryBlock   ::                 RpcQuery Block
  QueryBalance :: Addr         -> RpcQuery W256
  QueryNonce   :: Addr         -> RpcQuery W256
  QuerySlot    :: Addr -> W256 -> RpcQuery W256
  QueryChainId ::                 RpcQuery W256

data BlockNumber = Latest | BlockNumber W256
  deriving (Show, Eq)

deriving instance Show (RpcQuery a)

type RpcInfo = Maybe (BlockNumber, Text)

rpc :: String -> [Value] -> Value
rpc method args = object
  [ "jsonrpc" .= ("2.0" :: String)
  , "id"      .= Number 1
  , "method"  .= method
  , "params"  .= args
  ]

class ToRPC a where
  toRPC :: a -> Value

instance ToRPC Addr where
  toRPC = String . pack . show

instance ToRPC W256 where
  toRPC = String . pack . show

instance ToRPC Bool where
  toRPC = Bool

instance ToRPC BlockNumber where
  toRPC Latest          = String "latest"
  toRPC (EVM.Fetch.BlockNumber n) = String . pack $ show n

readText :: Read a => Text -> a
readText = read . unpack

fetchQuery
  :: Show a
  => BlockNumber
  -> (Value -> IO (Maybe Value))
  -> RpcQuery a
  -> IO (Maybe a)
fetchQuery n f q = do
  x <- case q of
    QueryCode addr -> do
        m <- f (rpc "eth_getCode" [toRPC addr, toRPC n])
        return $ hexText . view _String <$> m
    QueryNonce addr -> do
        m <- f (rpc "eth_getTransactionCount" [toRPC addr, toRPC n])
        return $ readText . view _String <$> m
    QueryBlock -> do
      m <- f (rpc "eth_getBlockByNumber" [toRPC n, toRPC False])
      return $ m >>= parseBlock
    QueryBalance addr -> do
        m <- f (rpc "eth_getBalance" [toRPC addr, toRPC n])
        return $ readText . view _String <$> m
    QuerySlot addr slot -> do
        m <- f (rpc "eth_getStorageAt" [toRPC addr, toRPC slot, toRPC n])
        return $ readText . view _String <$> m
    QueryChainId -> do
        m <- f (rpc "eth_chainId" [toRPC n])
        return $ readText . view _String <$> m
  return x


parseBlock :: (AsValue s, Show s) => s -> Maybe EVM.Block
parseBlock j = do
  coinbase   <- readText <$> j ^? key "miner" . _String
  timestamp  <- Lit . readText <$> j ^? key "timestamp" . _String
  number     <- readText <$> j ^? key "number" . _String
  gasLimit   <- readText <$> j ^? key "gasLimit" . _String
  let
   baseFee = readText <$> j ^? key "baseFeePerGas" . _String
   -- It seems unclear as to whether this field should still be called mixHash or renamed to prevRandao
   -- According to https://github.com/ethereum/EIPs/blob/master/EIPS/eip-4399.md it should be renamed
   -- but alchemy is still returning mixHash
   mixhash = readText <$> j ^? key "mixHash" . _String
   prevRandao = readText <$> j ^? key "prevRandao" . _String
   difficulty = readText <$> j ^? key "difficulty" . _String
   prd = case (prevRandao, mixhash, difficulty) of
     (Just p, _, _) -> p
     (Nothing, Just mh, Just 0x0) -> mh
     (Nothing, Just _, Just d) -> d
     _ -> error "Internal Error: block contains both difficulty and prevRandao"
  -- default codesize, default gas limit, default feescedule
  return $ EVM.Block coinbase timestamp number prd gasLimit (fromMaybe 0 baseFee) 0xffffffff FeeSchedule.berlin

fetchWithSession :: Text -> Session -> Value -> IO (Maybe Value)
fetchWithSession url sess x = do
  r <- asValue =<< Session.post sess (unpack url) x
  return (r ^? responseBody . key "result")

fetchContractWithSession
  :: BlockNumber -> Text -> Addr -> Session -> IO (Maybe Contract)
fetchContractWithSession n url addr sess = runMaybeT $ do
  let
    fetch :: Show a => RpcQuery a -> IO (Maybe a)
    fetch = fetchQuery n (fetchWithSession url sess)

  theCode    <- MaybeT $ fetch (QueryCode addr)
  theNonce   <- MaybeT $ fetch (QueryNonce addr)
  theBalance <- MaybeT $ fetch (QueryBalance addr)

  return $
    initialContract (EVM.RuntimeCode (EVM.ConcreteRuntimeCode theCode))
      & set nonce    theNonce
      & set balance  theBalance
      & set external True

fetchSlotWithSession
  :: BlockNumber -> Text -> Session -> Addr -> W256 -> IO (Maybe W256)
fetchSlotWithSession n url sess addr slot =
  fetchQuery n (fetchWithSession url sess) (QuerySlot addr slot)

fetchBlockWithSession
  :: BlockNumber -> Text -> Session -> IO (Maybe Block)
fetchBlockWithSession n url sess =
  fetchQuery n (fetchWithSession url sess) QueryBlock

fetchBlockFrom :: BlockNumber -> Text -> IO (Maybe Block)
fetchBlockFrom n url =
  Session.withAPISession
    (fetchBlockWithSession n url)

fetchContractFrom :: BlockNumber -> Text -> Addr -> IO (Maybe Contract)
fetchContractFrom n url addr =
  Session.withAPISession
    (fetchContractWithSession n url addr)

fetchSlotFrom :: BlockNumber -> Text -> Addr -> W256 -> IO (Maybe W256)
fetchSlotFrom n url addr slot =
  Session.withAPISession
    (\s -> fetchSlotWithSession n url s addr slot)

http :: Natural -> Maybe Natural -> BlockNumber -> Text -> Fetcher
http smtjobs smttimeout n url q =
  withSolvers Z3 smtjobs smttimeout $ \s ->
    oracle s (Just (n, url)) q

zero :: Natural -> Maybe Natural -> Fetcher
zero smtjobs smttimeout q =
  withSolvers Z3 smtjobs smttimeout $ \s ->
    oracle s Nothing q

-- smtsolving + (http or zero)
oracle :: SolverGroup -> RpcInfo -> Fetcher
oracle solvers info q = do
  case q of
    EVM.PleaseDoFFI vals continue -> case vals of
       cmd : args -> do
          (_, stdout', _) <- readProcessWithExitCode cmd args ""
          pure . continue . encodeAbiValue $
            AbiTuple (RegularVector.fromList [ AbiBytesDynamic . hexText . pack $ stdout'])
       _ -> error (show vals)

    EVM.PleaseAskSMT branchcondition pathconditions continue -> do
         let pathconds = foldl' PAnd (PBool True) pathconditions
         -- Is is possible to satisfy the condition?
         continue <$> checkBranch solvers (branchcondition ./= (Lit 0)) pathconds

    -- if we are using a symbolic storage model,
    -- we generate a new array to the fetched contract here
    EVM.PleaseFetchContract addr continue -> do
      contract <- case info of
                    Nothing -> return $ Just $ initialContract (EVM.RuntimeCode (EVM.ConcreteRuntimeCode ""))
                    Just (n, url) -> fetchContractFrom n url addr
      case contract of
        Just x -> return $ continue x
        Nothing -> error ("oracle error: " ++ show q)

    --EVM.PleaseMakeUnique val pathconditions continue ->
          --case smtstate of
            --Nothing -> return $ continue Multiple
            --Just state -> flip runReaderT state $ SBV.runQueryT $ do
              --constrain $ sAnd $ pathconditions <> [val .== val] -- dummy proposition just to make sure `val` is defined when we do `getValue` later.
              --checkSat >>= \case
                --Sat -> do
                  --val' <- getValue val
                  --s    <- checksat (val ./= literal val')
                  --case s of
                    --Unsat -> pure $ continue $ Unique val'
                    --_ -> pure $ continue Multiple
                --Unsat -> pure $ continue InconsistentU
                --Unk -> pure $ continue TimeoutU
                --DSat _ -> error "unexpected DSAT"


    EVM.PleaseFetchSlot addr slot continue ->
      case info of
        Nothing -> return (continue 0)
        Just (n, url) ->
         fetchSlotFrom n url addr (fromIntegral slot) >>= \case
           Just x  -> return (continue x)
           Nothing ->
             error ("oracle error: " ++ show q)

type Fetcher = EVM.Query -> IO (EVM ())

-- | Checks which branches are satisfiable, checking the pathconditions for consistency
-- if the third argument is true.
-- When in debug mode, we do not want to be able to navigate to dead paths,
-- but for normal execution paths with inconsistent pathconditions
-- will be pruned anyway.
checkBranch :: SolverGroup -> Prop -> Prop -> IO EVM.BranchCondition
checkBranch solvers branchcondition pathconditions = do
  checkSat solvers (assertProps [(branchcondition .&& pathconditions)]) >>= \case
     -- the condition is unsatisfiable
     Unsat -> -- if pathconditions are consistent then the condition must be false
            return $ EVM.Case False
     -- Sat means its possible for condition to hold
     Sat _ -> -- is its negation also possible?
            checkSat solvers (assertProps [(pathconditions .&& (PNeg branchcondition))]) >>= \case
               -- No. The condition must hold
               Unsat -> return $ EVM.Case True
               -- Yes. Both branches possible
               Sat _ -> return EVM.Unknown
               -- Explore both branches in case of timeout
               Unknown -> return EVM.Unknown
               Error e -> error $ "Internal Error: SMT Solver returned with an error: " <> T.unpack e
     -- If the query times out, we simply explore both paths
     Unknown -> return EVM.Unknown
     Error e -> error $ "Internal Error: SMT Solver returned with an error: " <> T.unpack e
