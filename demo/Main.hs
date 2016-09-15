{-# LANGUAGE OverloadedStrings
           , DeriveGeneric 
           , TypeApplications
           , TupleSections
           , ScopedTypeVariables
           , LambdaCase
           , TemplateHaskell
           #-}

module Main where

import Network.WebSockets
import Network.Wai.Handler.WebSockets
import Network.Wai.Handler.Warp
import Network.Wai
import Network.HTTP.Types
import Control.Exception
import Data.Aeson hiding ((.=))
import Data.Map (Map, (!), member, insert)
import qualified Data.Map as Map
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BS
import GHC.Generics

import System.IO
import System.IO.Error
import System.FilePath
import System.Directory
import Data.IORef
import Data.List hiding (insert)
import Data.Tuple
import Data.Maybe
import Control.Monad
import Control.Monad.State
import Control.Concurrent.MVar
import Control.Monad.IO.Class
import System.Environment

import GHC hiding (loadModule)
import Bag (bagToList)
import SrcLoc (realSrcSpanStart)
import ErrUtils (errMsgSpan)
import DynFlags (gopt_set)
import GHC.Paths ( libdir )
import GhcMonad (GhcMonad(..), Session(..), reflectGhc)
import HscTypes (SourceError, srcErrorMessages)
import FastString (unpackFS)

import Control.Reference as Ref

import Language.Haskell.Tools.AST
import Language.Haskell.Tools.Refactor
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.ASTDebug
import Language.Haskell.Tools.ASTDebug.Instances
import Language.Haskell.Tools.PrettyPrint

type ClientId = Int

main :: IO ()
main = do
    args <- getArgs
    wd <- case args of [dir] -> return dir
                       [] -> return "."
    counter <- newMVar []
    let settings = setPort 8206 $ setTimeout 20 $ defaultSettings 
    runSettings settings (app counter wd)

-- | The application that is evoked for each incoming request
app :: MVar [Int] -> FilePath -> Application
app sessions wd = websocketsOr defaultConnectionOptions wsApp backupApp
  where
    wsApp :: ServerApp
    wsApp conn = do
        conn <- acceptRequest conn
        newind <- modifyMVar sessions (\sess -> let smallest = head (filter (not . (`elem` sess)) [0..])
                                                 in return (smallest : sess, smallest))
        ghcSess <- initGhcSession (userDir wd newind)
        state <- newMVar initSession
        serverLoop newind ghcSess state conn

    serverLoop :: Int -> Session -> MVar RefactorSessionState -> Connection -> IO ()
    serverLoop sessId ghcSess state conn =
        do Text msg <- receiveDataMessage conn
           respondTo wd sessId ghcSess state (sendTextData conn) msg
           serverLoop sessId ghcSess state conn
      `catch` \(e :: ConnectionException) -> do 
                 modifyMVar_ sessions (return . delete sessId)
                 liftIO $ removeDirectoryIfPresent (userDir wd sessId)

    backupApp :: Application
    backupApp req respond = respond $ responseLBS status400 [] "Not a WebSocket request"

respondTo :: FilePath -> Int -> Session -> MVar RefactorSessionState -> (ByteString -> IO ()) -> ByteString -> IO ()
respondTo wd id ghcSess state next mess = case decode mess of
  Nothing -> next $ encode $ ErrorMessage "WRONG MESSAGE FORMAT"
  Just req -> handleErrors wd req (next . encode)
                $ do resp <- modifyMVar state (\st -> swap <$> reflectGhc (runStateT (updateClient (userDir wd id) req) st) ghcSess)
                     case resp of Just respMsg -> next $ encode respMsg
                                  Nothing -> return ()

-- | This function does the real job of acting upon client messages in a stateful environment of a client
updateClient :: FilePath -> ClientMessage -> StateT RefactorSessionState Ghc (Maybe ResponseMsg)
updateClient dir KeepAlive = return Nothing
updateClient dir (ModuleChanged name newContent) = do
    liftIO $ createFileForModule dir name newContent
    targets <- lift getTargets
    when (isNothing . find ((\case (TargetModule n) -> GHC.moduleNameString n == name; _ -> False) . targetId) $ targets)
      $ lift $ addTarget (Target (TargetModule (mkModuleName name)) True Nothing)
    lift $ load LoadAllTargets
    mod <- lift $ getModSummary (mkModuleName name) >>= parseTyped
    modify $ modColls & Ref.element 0 .- \mc -> mc { mcModules = Map.insert (mkAbsSrcKey dir name NormalHs) mod (mcModules mc) }
    return Nothing
updateClient dir (ModuleDeleted name) = do
    lift $ removeTarget (TargetModule (mkModuleName name))
    modify $ modColls & Ref.element 0 .- \mc -> mc { mcModules = Map.delete (mkAbsSrcKey dir name NormalHs) (mcModules mc) }
    return Nothing
updateClient dir (InitialProject modules) = do 
    -- clean the workspace to remove source files from earlier sessions
    liftIO $ removeDirectoryIfPresent dir
    liftIO $ createDirectoryIfMissing True dir
    liftIO $ forM modules $ \(mod, cont) -> do
      withBinaryFile (toFileName dir mod) WriteMode (`hPutStr` cont)
    lift $ setTargets (map ((\modName -> Target (TargetModule (mkModuleName modName)) True Nothing) . fst) modules)
    lift $ load LoadAllTargets
    forM (map fst modules) $ \modName -> do
      mod <- lift $ getModSummary (mkModuleName modName) >>= parseTyped
      modify $ modColls & Ref.element 0 .- \mc -> mc { mcModules = Map.insert (mkAbsSrcKey dir modName NormalHs) mod (mcModules mc) }
    return Nothing
updateClient dir (PerformRefactoring "UpdateAST" modName _ _) = do
    mod <- gets (Map.lookup (mkAbsSrcKey dir modName NormalHs) . mcModules . fromJust . (^? modColls & Ref.element 0))
    case mod of Just m -> return $ Just $ ASTViewContent $ astDebug m
                Nothing -> return $ Just $ ErrorMessage "The module is not found"
updateClient _ (PerformRefactoring "TestErrorLogging" _ _ _) = error "This is a test"
updateClient dir (PerformRefactoring refact modName selection args) = do
    allModules <- gets (map moduleNameAndContent . Map.assocs . mcModules . fromJust . (^? modColls & Ref.element 0))
    let (otherModules, [mod]) = partition ((== modName) . fst) allModules
        command = analyzeCommand (toFileName dir modName) refact (selection:args)
    res <- lift $ performCommand command mod otherModules 
    case res of
      Left err -> return $ Just $ ErrorMessage err
      Right diff -> do applyChanges diff
                       return $ Just $ RefactorChanges (map trfDiff diff)
  where trfDiff (ContentChanged (name,cont)) = (name, Just (prettyPrint cont))
        trfDiff (ModuleRemoved name) = (name, Nothing)

        applyChanges chs 
          = do reload <- forM chs $ \case 
                 ContentChanged (n,m) -> do
                   liftIO $ withBinaryFile (toFileName dir n) WriteMode (`hPutStr` prettyPrint m)
                   ms <- lookupModuleSummary m
                   return $ Just (n, ms)
                 ModuleRemoved mod -> do
                   liftIO $ removeFile (toFileName dir mod)
                   modify $ modColls & Ref.element 0 .- \mc -> mc { mcModules = Map.delete (mkAbsSrcKey dir mod NormalHs) (mcModules mc) }
                   return Nothing
               lift $ load LoadAllTargets
               forM (catMaybes reload) $ \(n, ms) -> do
                   newm <- lift $ (parseTyped ms)
                   modify $ modColls & Ref.element 0 .- \mc -> mc { mcModules = Map.insert (mkAbsSrcKey dir n NormalHs) newm (mcModules mc) }

createFileForModule :: FilePath -> String -> String -> IO ()
createFileForModule dir name newContent = do
  let fname = toFileName dir name
  createDirectoryIfMissing True (takeDirectory fname)
  withBinaryFile fname WriteMode (`hPutStr` newContent) 

removeDirectoryIfPresent :: FilePath -> IO ()
removeDirectoryIfPresent dir = removeDirectoryRecursive dir `catch` \e -> if isDoesNotExistError e then return () else throwIO e

moduleNameAndContent :: (AbsoluteSourceKey, mod) -> (String, mod)
moduleNameAndContent (abs, mod) = (askModule abs, mod)

dataDirs :: FilePath -> FilePath
dataDirs wd = wd </> "demoSources"

userDir :: FilePath -> ClientId -> FilePath
userDir wd id = dataDirs wd </> show id

initGhcSession :: FilePath -> IO Session
initGhcSession workingDir = Session <$> (newIORef =<< runGhc (Just libdir) (do 
    dflags <- getSessionDynFlags
    -- don't generate any code
    setSessionDynFlags 
      $ flip gopt_set Opt_KeepRawTokenStream
      $ flip gopt_set Opt_NoHsMain
      $ dflags { importPaths = [workingDir]
               , hscTarget = HscAsm -- needed for static pointers
               , ghcLink = LinkInMemory
               , ghcMode = CompManager 
               }
    getSession))

handleErrors :: FilePath -> ClientMessage -> (ResponseMsg -> IO ()) -> IO () -> IO ()
handleErrors wd req next io = io `catch` (next <=< handleException)
  where handleException :: SomeException -> IO ResponseMsg
        handleException e 
          | Just (se :: SourceError) <- fromException e 
          = return $ CompilationProblem (concatMap (\msg -> showMsg msg ++ "\n\n") $ bagToList $ srcErrorMessages se)
          | Just (ae :: AsyncException) <- fromException e = throw ae
          | Just (ge :: GhcException) <- fromException e = return $ ErrorMessage $ show ge
          | otherwise = do logToFile wd (show e) req
                           return $ ErrorMessage (showInternalError e)
        
        showMsg msg = showSpan (errMsgSpan msg) ++ "\n" ++ show msg
        showSpan (RealSrcSpan sp) = showFileName (srcLocFile (realSrcSpanStart sp)) ++ " " ++ show (srcLocLine (realSrcSpanStart sp)) ++ ":" ++ show (srcLocCol (realSrcSpanStart sp))
        showSpan _ = ""

        showFileName = joinPath . drop 2 . splitPath . makeRelative wd . unpackFS

        showInternalError :: SomeException -> String
        showInternalError e = "An internal error happened. The report has been sent to the developers. " ++ show e

logToFile :: FilePath -> String -> ClientMessage -> IO ()
logToFile wd err input = do
  let msg = err ++ "\n with input: " ++ show input
  withFile logFile AppendMode $ \handle -> do
      size <- hFileSize handle
      when (size < logSizeLimit) $ hPutStrLn handle ("\n### " ++ msg)
    `catch` \e -> print ("The error message cannot be logged because: " 
                             ++ show (e :: IOException) ++ "\nHere is the message:\n" ++ msg) 
  where logFile = wd </> "error-log.txt"
        logSizeLimit = 100 * 1024 * 1024 -- 100 MB

data ClientMessage
  = KeepAlive
  | InitialProject { initialModules :: [(String,String)] }
  | PerformRefactoring { refactoring :: String
                       , moduleName :: String
                       , editorSelection :: String
                       , details :: [String]
                       }
  | ModuleChanged { moduleName :: String
                  , newContent :: String
                  }
  | ModuleDeleted { moduleName :: String }
  deriving (Eq, Show, Generic)

instance ToJSON ClientMessage
instance FromJSON ClientMessage 

data ResponseMsg
  = RefactorChanges { moduleChanges :: [(String, Maybe String)] }
  | ASTViewContent { astContent :: String }
  | ErrorMessage { errorMsg :: String }
  | CompilationProblem { errorMsg :: String }
  deriving (Eq, Show, Generic)

instance ToJSON ResponseMsg
instance FromJSON ResponseMsg 
