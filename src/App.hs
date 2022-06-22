module App (DbConnectionAcquireException (..), bootstrapEnvFromConfig, appService) where

import Control.Exception (Exception, try)
import Control.Monad.Catch (throwM)
import Control.Monad.Except (ExceptT (ExceptT))
import Control.Monad.Logger (runStdoutLoggingT)
import Control.Monad.Reader (runReaderT)
import Data.Aeson (eitherDecode)
import Data.Default (def)
import Data.Maybe (fromMaybe)
import Hasql.Connection qualified as Hasql
import Servant.API.Generic (ToServantApi)
import Servant.Server (
  Application,
  BasicAuthCheck,
  Context (EmptyContext, (:.)),
  Handler (Handler),
  ServerT,
  hoistServerWithContext,
  serveWithContext,
 )
import Servant.Server.Generic (genericServerT)

import Api (Routes, datumCacheApi, datumCacheContext)
import Api.Handler (controlApiAuthCheck, datumServiceHandlers)
import Api.Types (ControlApiAuthData)
import App.Env (
  Env (Env, envBlockFetcherEnv, envBlockProcessorEnv, envControlApiToken, envDbConnection),
 )
import App.Types (App (unApp))
import Block.Fetch (
  OgmiosInfo (OgmiosInfo),
  startBlockFetcherAndProcessor,
 )
import Database (getLastBlock, initLastBlock, initTables, updateLastBlock)
import Parameters (Config)

newtype DbConnectionAcquireException
  = DbConnectionAcquireException Hasql.ConnectionError
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

appService :: Env -> Application
appService env =
  serveWithContext datumCacheApi serverContext appServer
  where
    appServer :: ServerT (ToServantApi Routes) Handler
    appServer =
      hoistServerWithContext
        datumCacheApi
        datumCacheContext
        hoistApp
        appServerT

    serverContext :: Context '[BasicAuthCheck ControlApiAuthData]
    serverContext = controlApiAuthCheck env :. EmptyContext

    hoistApp :: App a -> Handler a
    hoistApp = Handler . ExceptT . try . runStdoutLoggingT . flip runReaderT env . unApp

    appServerT :: ServerT (ToServantApi Routes) App
    appServerT = genericServerT datumServiceHandlers

-- | Connect to database, start block fetcher and block processor
bootstrapEnvFromConfig :: Config -> IO Env
bootstrapEnvFromConfig cfg = do
  dbConn <-
    Hasql.acquire cfg.cfgDbConnectionString
      >>= either (throwM . DbConnectionAcquireException) pure
  runStdoutLoggingT . flip runReaderT dbConn $ do
    initTables
    let datumFilter' = case cfg.cfgFetcher.cfgFetcherFilterJson of
          Just filterJson -> eitherDecode filterJson
          Nothing -> pure def
    datumFilter <- case datumFilter' of
      Left e -> error $ show e
      Right x -> pure x
    latestBlock' <- getLastBlock dbConn
    let firstBlock =
          if cfg.cfgFetcher.cfgFetcherUseLatest
            then fromMaybe cfg.cfgFetcher.cfgFetcherBlock latestBlock'
            else cfg.cfgFetcher.cfgFetcherBlock
    initLastBlock firstBlock
    updateLastBlock dbConn firstBlock
    let ogmiosInfo = OgmiosInfo cfg.cfgOgmiosPort cfg.cfgOgmiosAddress
    (blockFetcherEnv, blockProcessorEnv) <-
      startBlockFetcherAndProcessor
        ogmiosInfo
        dbConn
        firstBlock
        datumFilter
        cfg.cfgFetcher.cfgFetcherQueueSize
    pure $
      Env
        { envBlockFetcherEnv = blockFetcherEnv
        , envDbConnection = dbConn
        , envBlockProcessorEnv = blockProcessorEnv
        , envControlApiToken = cfg.cfgServerControlApiToken
        }
