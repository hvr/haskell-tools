 {-# LANGUAGE StandaloneDeriving
            , DeriveGeneric
            #-}
module Language.Haskell.Tools.Debug where

import Control.Monad.IO.Class
import GHC.Generics hiding (moduleName)
import Data.Maybe

import GHC hiding (loadModule)
import GHC.Paths ( libdir )
import Module as GHC
import SrcLoc
import HscTypes

import Language.Haskell.Tools.AST
import Language.Haskell.Tools.AST.FromGHC
import Language.Haskell.Tools.AnnTrf.RangeToRangeTemplate
import Language.Haskell.Tools.AnnTrf.RangeTemplateToSourceTemplate
import Language.Haskell.Tools.AnnTrf.SourceTemplate
import Language.Haskell.Tools.AnnTrf.RangeTemplate
import Language.Haskell.Tools.AnnTrf.PlaceComments
import Language.Haskell.Tools.PrettyPrint
import Language.Haskell.Tools.DebugGhcAST
import Language.Haskell.Tools.RangeDebug
import Language.Haskell.Tools.RangeDebug.Instances
import Language.Haskell.Tools.Refactor
import Language.Haskell.Tools.Refactor.RefactorBase

-- | Should be only used for testing
demoRefactor :: String -> String -> [String] -> String -> IO ()
demoRefactor command workingDir args moduleName = 
  runGhc (Just libdir) $ do
    initGhcFlags
    useFlags args
    useDirs [workingDir]
    modSum <- loadModule workingDir moduleName
    p <- parseModule modSum
    t <- typecheckModule p
        
    let r = tm_renamed_source t
    let annots = pm_annotations $ tm_parsed_module t

    liftIO $ putStrLn $ show annots
    liftIO $ putStrLn "==========="
    liftIO $ putStrLn $ show (pm_parsed_source p)
    liftIO $ putStrLn "==========="
    liftIO $ putStrLn $ show (fromJust $ tm_renamed_source t)
    liftIO $ putStrLn "==========="
    liftIO $ putStrLn $ show (typecheckedSource t)
    liftIO $ putStrLn "=========== parsed:"
    --transformed <- runTrf (fst annots) (getPragmaComments $ snd annots) $ trfModule (pm_parsed_source p)
    parseTrf <- runTrf (fst annots) (getPragmaComments $ snd annots) $ trfModule modSum (pm_parsed_source p)
    liftIO $ putStrLn $ srcInfoDebug parseTrf
    liftIO $ putStrLn "=========== typed:"
    transformed <- addTypeInfos (typecheckedSource t) =<< (runTrf (fst annots) (getPragmaComments $ snd annots) $ trfModuleRename modSum parseTrf (fromJust $ tm_renamed_source t) (pm_parsed_source p))
    liftIO $ putStrLn $ srcInfoDebug transformed
    liftIO $ putStrLn "=========== ranges fixed:"
    let commented = fixRanges $ placeComments (getNormalComments $ snd annots) transformed
    liftIO $ putStrLn $ srcInfoDebug commented
    liftIO $ putStrLn "=========== cut up:"
    let cutUp = cutUpRanges commented
    liftIO $ putStrLn $ srcInfoDebug cutUp
    liftIO $ putStrLn $ show $ getLocIndices cutUp
    liftIO $ putStrLn $ show $ mapLocIndices (fromJust $ ms_hspp_buf $ pm_mod_summary p) (getLocIndices cutUp)
    liftIO $ putStrLn "=========== sourced:"
    let sourced = rangeToSource (fromJust $ ms_hspp_buf $ pm_mod_summary p) cutUp
    liftIO $ putStrLn $ srcInfoDebug sourced
    liftIO $ putStrLn "=========== pretty printed:"
    let prettyPrinted = prettyPrint sourced
    liftIO $ putStrLn prettyPrinted
    transformed <- performCommand (readCommand (fromJust $ ml_hs_file $ ms_location modSum) command) (moduleName, sourced) []
    case transformed of 
      Right [ContentChanged (_, correctlyTransformed)] -> do
        liftIO $ putStrLn "=========== transformed AST:"
        liftIO $ putStrLn $ srcInfoDebug correctlyTransformed
        liftIO $ putStrLn "=========== transformed & prettyprinted:"
        let prettyPrinted = prettyPrint correctlyTransformed
        liftIO $ putStrLn prettyPrinted
        liftIO $ putStrLn "==========="
      Left transformProblem -> do
        liftIO $ putStrLn "==========="
        liftIO $ putStrLn transformProblem
        liftIO $ putStrLn "==========="
  
deriving instance Generic SrcSpan
deriving instance (Generic sema, Generic src) => Generic (NodeInfo sema src)
