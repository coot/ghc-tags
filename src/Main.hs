{-# LANGUAGE CPP #-}
module Main (main) where

import Control.Arrow ((&&&))
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.DeepSeq
import Control.Exception
import Control.Monad
import Data.Bifunctor
import Data.Char
import Data.Function
import Data.List
import Data.Maybe (mapMaybe)
import Data.Time
import Data.Time.Format.ISO8601
import Data.Version
import GHC (GhcException, setSessionDynFlags)
import GHC.Conc (getNumProcessors)
import GHC.Data.Bag
import GHC.Data.StringBuffer
import GHC.Driver.Env.Types
import GHC.Driver.Monad
import GHC.Driver.Pipeline
import GHC.Driver.Ppr
import GHC.Driver.Session
import GHC.Hs
#if !MIN_VERSION_GHC(9,4)
import GHC.Parser.Errors.Ppr
#endif
import GHC.Parser.Lexer
#if MIN_VERSION_GHC(9,4)
import GHC.Types.Error
#endif
import GHC.Types.SrcLoc
import GHC.Utils.Error
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.IO.Error
import System.IO.Temp
import System.Process
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Char8 as BS
import qualified Data.Foldable as F
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import Paths_ghc_tags (version)

import GhcTags
import GhcTags.Config.Args
import GhcTags.Config.Project
import GhcTags.CTag.Header
import GhcTags.GhcCompat
import qualified GhcTags.CTag as CTag
import qualified GhcTags.ETag as ETag

----------------------------------------

data Updated a = Updated Bool a

data HsFileType = HsFile | HsBootFile | LHsFile | AlexFile | HscFile

data WorkerData = WorkerData
  { wdTags   :: MVar DirtyTags
  , wdTimes  :: MVar DirtyModTimes
  , wdQueue  :: TBQueue (Maybe (FilePath, HsFileType, UTCTime))
  }

generateTagsForProject :: Int -> WorkerData -> ProjectConfig -> IO ()
generateTagsForProject threads wd pc = runConcurrently . F.fold
  $ Concurrently (processFiles (pcSourcePaths pc) >> terminateWorkers)
  : replicate threads (Concurrently worker)
  where
    -- Walk a list of paths recursively and process eligible source files.
    processFiles :: [String] -> IO ()
    processFiles = mapM_ $ \origPath -> do
      let path = normalise origPath
      unless (path `elem` pcExcludePaths pc) $ do
        doesDirectoryExist path >>= \case
          True -> do
            paths <- map (path </>) <$> listDirectory path
            processFiles paths
          False -> F.forM_ (takeExtension path `lookup` haskellExts) $ \hsType -> do
            showIOError $ do
              -- Source files are scanned and updated only if their mtime changed or
              -- it's not recorded.
              time <- getModificationTime path
              updateTags <- withMVar (wdTimes wd) $ \times -> pure $
                case TagFilePath (T.pack path) `Map.lookup` times of
                  -- If the file was already updated, it means it's eligible for
                  -- the update with regard to its mtime, but it was already
                  -- processed. In such case we let it through in order to
                  -- support the case of parsing the same file multiple times
                  -- with different CPP options.
                  Just (Updated updated oldTime) -> updated || oldTime < time
                  Nothing                        -> True
              when updateTags $ do
                atomically . writeTBQueue (wdQueue wd) $ Just (path, hsType, time)
      where
        haskellExts = [ (".hs",      HsFile)
                      , (".hs-boot", HsBootFile)
                      , (".lhs",     LHsFile)
                      , (".x",       AlexFile)
                      , (".hsc",     HscFile)
                      ]

    terminateWorkers :: IO ()
    terminateWorkers = atomically $ do
      replicateM_ threads $ writeTBQueue (wdQueue wd) Nothing

    showIOError m = m `catch` \(e::IOError) -> do
      putStrLn $ "Error: " ++ show e

    -- Extract tags from a given file and update the TagMap.
    worker :: IO ()
    worker = runGhc $ do
      void $ setSessionDynFlags . adjustDynFlags pc =<< getSessionDynFlags
      env <- getSession
      liftIO . fix $ \loop -> atomically (readTBQueue $ wdQueue wd) >>= \case
        Nothing                    -> pure ()
        Just (file, hsType, mtime) -> do
          showIOError $ processFile env file hsType mtime
          loop
      where
        processFile :: HscEnv -> FilePath -> HsFileType -> UTCTime -> IO ()
        processFile env rawFile hsType mtime = withHsFile rawFile hsType $ \hsFile -> do
          handle showErr $ preprocess env hsFile Nothing Nothing >>= \case
            Left errs -> report (hsc_dflags env)
#if MIN_VERSION_GHC(9,4)
                                                 (getMessages errs)
#else
                                                 errs
#endif
            Right (flags, file) -> do
              --when (file /= rawFile) $ do
              --  putStrLn $ "Processing " ++ file ++ " (" ++ rawFile ++ ")"
              buffer <- hGetStringBuffer file
              case parseModule file flags buffer of
                PFailed pstate -> do
#if MIN_VERSION_GHC(9,4)
                  let (wrns, errs) = getPsMessages pstate
                  report flags (getMessages wrns)
                  report flags (getMessages errs)
#else
                  let (wrns, errs) = getMessages pstate
                  report flags (pprWarning <$> wrns)
                  report flags (pprError <$> errs)
#endif
                POk pstate hsModule -> do
#if MIN_VERSION_GHC(9,4)
                  let (wrns, errs) = getPsMessages pstate
                  report flags (getMessages wrns)
                  report flags (getMessages errs)
#else
                  let (wrns, errs) = getMessages pstate
                  report flags (pprWarning <$> wrns)
                  report flags (pprError <$> errs)
#endif
#if MIN_VERSION_GHC(9,4)
                  when (isEmptyMessages errs) $ do
#else
                  when (isEmptyBag errs) $ do
#endif
                    modifyMVar_ (wdTags wd) $ \tags -> do
                      pure $! updateTagsWith flags hsModule tags
                    modifyMVar_ (wdTimes wd) $ \times -> do
                      let path = TagFilePath $ T.pack rawFile
                      pure $! updateTimesWith path mtime times
          where
            showErr :: GHC.GhcException -> IO ()
            showErr = putStrLn . show

#if MIN_VERSION_GHC(9,4)
            report :: Diagnostic e =>
                      DynFlags -> Bag (MsgEnvelope e) -> IO ()
#else
            report :: DynFlags -> Bag (MsgEnvelope DecoratedSDoc) -> IO ()
#endif
            report flags msgs =
              sequence_ [ putStrLn $ showSDoc flags msg
                        | msg <- pprMsgEnvelopeBagWithLoc msgs
                        ]

        -- Alex and Hsc files need to be preprocessed before going into GHC.
        withHsFile :: FilePath -> HsFileType -> (FilePath -> IO ()) -> IO ()
        withHsFile file hsType k = case hsType of
          AlexFile -> preprocessWith "alex" []
          HscFile  -> preprocessWith "hsc2hs" $ map ("-I" ++) (pcCppIncludes pc)
                                   ++ filter ("-D" `isPrefixOf`) (pcCppOptions pc)
          _        -> k file
          where
            preprocessWith :: FilePath -> [FilePath] -> IO ()
            preprocessWith prog args = withSystemTempDirectory "ghc-tags" $ \dir -> do
              let tmpFile = dir </> "out.hs"
              (ec, out, err) <- readProcessWithExitCode prog
                ([file, "-o", tmpFile] ++ args) ""
              case ec of
                ExitSuccess      -> k tmpFile
                ExitFailure code -> do
                  putStrLn $ "Preprocessing " ++ file ++ " with " ++ prog
                          ++ " failed with exit code " ++ show code
                  unless (null out) . putStrLn $ "* STDOUT: " ++ out
                  unless (null err) . putStrLn $ "* STDERR: " ++ err

main :: IO ()
main = do
  -- The default number of threads is half the number of CPU cores as usually
  -- the other half are logical cores that don't increase performance when
  -- loaded (or even decrease it in case of high core count, e.g. Ryzen 5950x).
  defaultThreads <- max 1 . (`div` 2) <$> getNumProcessors

  args <- parseArgs defaultThreads =<< getArgs

  pcs <- case aSourcePaths args of
    SourceArgs paths      -> pure [defaultProjectConfig { pcSourcePaths = paths }]
    ConfigFile configFile -> getProjectConfigs configFile

  when (not $ null pcs) $ do
    wd <- initWorkerData args (aThreads args)

    setNumCapabilities (aThreads args)
    forM_ pcs $ generateTagsForProject (aThreads args) wd
    setNumCapabilities 1

    cleanTagMap <- withMVar (wdTags wd) (cleanupTags args)
    writeTags (aTagFile args) cleanTagMap
    withMVar (wdTimes wd) $ writeTimes (timesFile args) <=< cleanupTimes cleanTagMap
  where
    timesFile args = aTagFile args <.> "mtime"

    initWorkerData :: Args -> Int -> IO WorkerData
    initWorkerData args threads = do
      tags@DirtyTags{dtTags} <- case aTagType args of
        ETAG -> readTags SingETag (aTagFile args)
        CTAG -> readTags SingCTag (aTagFile args)
      -- If tags are empty there is no point looking at mtimes.
      mtimes <- if Map.null dtTags
        then pure Map.empty
        else readTimes (timesFile args)
      wdTags  <- newMVar tags
      wdTimes <- newMVar mtimes
      wdQueue <- newTBQueueIO (fromIntegral threads)
      pure WorkerData{..}

----------------------------------------

type DirtyModTimes = Map.Map TagFilePath (Updated UTCTime)
type ModTimes      = Map.Map TagFilePath UTCTime

-- | Read the file with mtimes of previously processed source files.
readTimes :: FilePath -> IO DirtyModTimes
readTimes timesFile = doesFileExist timesFile >>= \case
  False -> pure Map.empty
  True  -> tryIOError (T.readFile timesFile) >>= \case
    Right content -> pure . parse Map.empty $ T.lines content
    Left err -> do
      putStrLn $ "Error while reading " ++ timesFile ++ ": " ++ show err
      pure Map.empty
  where
    parse :: DirtyModTimes -> [T.Text] -> DirtyModTimes
    parse !acc (path : mtime : rest) =
      case iso8601ParseM (T.unpack mtime) of
        Just time -> let checkedTime = Updated False time
                     in parse (Map.insert (TagFilePath path) checkedTime acc) rest
        Nothing   -> parse acc rest
    parse !acc _ = acc

-- | Update an mtime of a source file with a new value.
updateTimesWith :: TagFilePath -> UTCTime -> DirtyModTimes -> DirtyModTimes
updateTimesWith file time = Map.insert file (Updated True time)

-- | Check if files that were not updated exist and drop them if they don't.
cleanupTimes :: Tags -> DirtyModTimes -> IO ModTimes
cleanupTimes Tags{..} = Map.traverseMaybeWithKey $ \file -> \case
  Updated updated time
    | updated || file `Map.member` tTags -> pure $ Just time
    | otherwise -> do
        let path = T.unpack $ getRawFilePath file
        doesFileExist path >>= \case
          True  -> pure $ Just time
          False -> pure Nothing

-- | Update the file with mtimes with new values.
writeTimes :: FilePath -> ModTimes -> IO ()
writeTimes timesFile times = withFile timesFile WriteMode $ \h -> do
  forM_ (Map.toList times) $ \(path, mtime) -> do
    T.hPutStrLn h $ getRawFilePath path
    hPutStrLn h $ iso8601Show mtime

----------------------------------------

data DirtyTags = forall tt. DirtyTags
  { dtKind    :: SingTagKind tt
  , dtHeaders :: [CTag.Header]
  , dtTags    :: Map.Map TagFilePath (Updated (Set.Set (Tag tt)))
  }

data Tags = forall tt. Tags
  { tKind    :: SingTagKind tt
  , tHeaders :: [CTag.Header]
  , tTags    :: Map.Map TagFilePath [Tag tt]
  }

readTags :: forall tt. SingTagKind tt -> FilePath -> IO DirtyTags
readTags tt tagsFile = doesFileExist tagsFile >>= \case
  False -> pure newDirtyTags
  True  -> do
    res <- tryIOError $ parseTagsFile =<< BS.readFile tagsFile
    case res of
      Right (Right (headers, tags)) ->
        -- full evaluation decreases performance variation
        deepseq headers `seq` deepseq tags `seq` pure DirtyTags
        { dtKind = tt
        , dtHeaders = headers , dtTags = Map.map (Updated False . Set.fromList) tags
        }
      -- reading failed
      Left err -> do
        putStrLn $ "Error while reading " ++ tagsFile ++ ": " ++ show err
        pure newDirtyTags
      -- parsing failed
      Right (Left err) -> do
        putStrLn $ "Error while parsing " ++ tagsFile ++ ": " ++ show err
        pure newDirtyTags
  where
    newDirtyTags = DirtyTags { dtKind = tt
                             , dtHeaders = []
                             , dtTags = Map.empty
                             }

    parseTagsFile
      :: BS.ByteString
      -> IO (Either String ([CTag.Header], Map.Map TagFilePath [Tag tt]))
    parseTagsFile = case tt of
      SingETag -> fmap (fmap ([], )) . ETag.parseTagsFileMap
      SingCTag ->                      CTag.parseTagsFileMap

updateTagsWith :: DynFlags -> Located HsModule -> DirtyTags -> DirtyTags
updateTagsWith dflags hsModule DirtyTags{..} =
  DirtyTags { dtTags = Map.unionWith mergeTags fileTags dtTags
            , ..
            }
  where
    mergeTags (Updated newUpdated newTags) (Updated oldUpdated oldTags) =
      -- If the file was already updated, we merge tags. This supports the case
      -- of parsing the same file multiple times with different CPP options.
      if oldUpdated
      then Updated newUpdated $!! newTags `Set.union` oldTags
      else Updated newUpdated $!! newTags

    fileTags =
      let tags = Map.fromListWith Set.union
               . map (second Set.singleton)
               . mapMaybe (fmap (tagFilePath &&& id) . ghcTagToTag dtKind dflags)
               $ getGhcTags hsModule
      in Map.map (Updated True) tags

cleanupTags :: Args -> DirtyTags -> IO Tags
cleanupTags args DirtyTags{..} = do
  newTags <- (`Map.traverseMaybeWithKey` dtTags) $ \file (Updated updated tags) -> do
    let path = T.unpack $ getRawFilePath file
    -- The file might not exists even though it was updated, e.g. when .x files
    -- are preprocessed as temporary files, some tags from them might make it
    -- here.
    exists <- doesFileExist path
    if | exists && updated -> do
           let cleanedTags = ignoreSimilarClose dtKind . sortBy compareNAK $ Set.toList tags
           case dtKind of
             SingCTag -> if aExModeSearch args
               then addExCommands file cleanedTags
               else pure $ Just cleanedTags
             SingETag -> addFileOffsets file cleanedTags
       | exists && not updated -> pure . Just $ Set.toList tags
       | otherwise -> pure Nothing
  newTags `deepseq` pure Tags { tKind = dtKind
                              , tHeaders = dtHeaders
                              , tTags = newTags
                              }
  where
    -- Group the same tags together so that similar ones can be eliminated.
    compareNAK t0 t1 = on compare tagName t0 t1
                    <> on compare tagAddr t0 t1
                    <> on compare tagKind t0 t1

    ignoreSimilarClose :: SingTagKind tk -> [Tag tk] -> [Tag tk]
    ignoreSimilarClose dtKind' (a : b : rest)
      | tagName a == tagName b =
        if | a `betterThan` b -> a <> b : ignoreSimilarClose dtKind' rest
           | b `betterThan` a -> b <> a : ignoreSimilarClose dtKind' rest
           | otherwise        -> a : ignoreSimilarClose dtKind' (b : rest)
      | otherwise = a : ignoreSimilarClose dtKind' (b : rest)
      where
        -- Prefer definitions of functions and pattern synonyms over their type
        -- signatures and data/GADT constructors over type constructors.
        x `betterThan` y
          =  (   (tagKind x == TkFunction || tagKind x == TkPatternSynonym)
              && tagKind y == TkTypeSignature
             )
          || (   (tagKind x == TkDataConstructor || tagKind x == TkGADTConstructor)
              &&  tagKind y == TkTypeConstructor
             )
    ignoreSimilarClose _ tags = tags
                                                                                                                  


-- | Convert 'tagAddress' of CTags to an Ex mode search command as some editors
-- (e.g. Kate) don't support jumping to a line number and require a line match.
addExCommands :: TagFilePath -> [CTag] -> IO (Maybe [CTag])
addExCommands file tags = do
  let path = T.unpack $ getRawFilePath file
  tryIOError (BS.readFile path) >>= \case
    Left err -> do
      putStrLn $ "Unexpected error: " ++ show err
      pure Nothing
    Right content -> do
      let fileLines = V.fromList $ BS.lines content
      pure . Just $ fillExCommands fileLines tags
  where
    fillExCommands :: V.Vector BS.ByteString -> [CTag] -> [CTag]
    fillExCommands fileLines = mapMaybe $ \tag -> case tagAddr tag of
        TagCommand{}        -> Just tag
        TagLine lineNo      -> go lineNo tag
        TagLineCol lineNo _ -> go lineNo tag
      where
        go :: Int -> CTag -> Maybe CTag
        go lineNo tag = do
            line <- fileLines V.!? (lineNo - 1)
            let TagFields fields = tagFields tag
                -- Ex mode forward search command. Slashes need to be escaped.
                exCommand = T.concat ["/^", T.replace "/" "\\/" $ T.decodeUtf8 line, "$/"]
            pure tag
              { tagAddr = TagCommand $ ExCommand exCommand
              , tagFields = TagFields $ TagField "line" (T.pack $ show lineNo) : fields
              }

-- | Add file offsets to etags from a specific file.
addFileOffsets :: TagFilePath -> [ETag] -> IO (Maybe [ETag])
addFileOffsets file tags = do
  let path = T.unpack $ getRawFilePath file
      addOffset !off line = (off + BS.length line + 1, (off, line))
  tryIOError (BS.readFile path) >>= \case
    Left err -> do
      putStrLn $ "Unexpected error: " ++ show err
      pure Nothing
    Right content -> do
      let linesWithOffsets = V.fromList
                           . snd
                           . mapAccumL addOffset 0
                           . BS.lines
                           $ content
      pure . Just $ fillOffsets linesWithOffsets tags
  where
    fillOffsets :: V.Vector (Int, BS.ByteString) -> [ETag] -> [ETag]
    fillOffsets linesWithOffsets = mapMaybe $ \tag -> do
      let lineNo = case tagAddr tag of
                     TagLineCol a _ -> a
                     TagLine a      -> a
                     _              -> error "ghc-tags: no tag address"
      (offset, line) <- linesWithOffsets V.!? (lineNo - 1)
      pure tag
        { tagAddr       = TagLineCol lineNo offset
        , tagDefinition =
          -- Prevent weird characters from ending up in the TAGS file.
          TagDefinition . T.takeWhile isPrint $ T.decodeUtf8 line
        }

writeTags :: FilePath -> Tags -> IO ()
writeTags tagsFile Tags{..} = withFile tagsFile WriteMode $ \h ->
  BS.hPutBuilder h $ case tKind of
    SingETag -> foldMap (ETag.formatETagsFile . sortBy ETag.compareTags) tTags
    SingCTag -> CTag.formatTagsFileMap headers tTags
  where
    headers :: [Header]
    headers = if null tHeaders
              then defaultHeaders
              else tHeaders

defaultHeaders :: [Header]
defaultHeaders =
  [ Header FileFormat     Nothing 2 ""
  , Header FileSorted     Nothing 1 ""
  , Header FileEncoding   Nothing "utf-8" ""
  , Header ProgramName    Nothing "ghc-tags" ""
  , Header ProgramUrl     Nothing "https://hackage.haskell.org/package/ghc-tags" ""
  , Header ProgramVersion Nothing (T.pack $ showVersion version) ""

  , Header FieldDescription haskellLang "type" "type of expression"
  , Header FieldDescription haskellLang "ffi"  "foreign object name"
  , Header FieldDescription haskellLang "file" "not exported term"
  , Header FieldDescription haskellLang "instance" "class, type or data type instance"
  , Header FieldDescription haskellLang "Kind" "kind of a type"

  , Header KindDescription haskellLang "M" "module"
  , Header KindDescription haskellLang "f" "function"
  , Header KindDescription haskellLang "A" "type constructor"
  , Header KindDescription haskellLang "c" "data constructor"
  , Header KindDescription haskellLang "g" "gadt constructor"
  , Header KindDescription haskellLang "r" "record field"
  , Header KindDescription haskellLang "=" "type synonym"
  , Header KindDescription haskellLang ":" "type signature"
  , Header KindDescription haskellLang "p" "pattern synonym"
  , Header KindDescription haskellLang "C" "type class"
  , Header KindDescription haskellLang "m" "type class member"
  , Header KindDescription haskellLang "i" "type class instance"
  , Header KindDescription haskellLang "T" "type family"
  , Header KindDescription haskellLang "t" "type family instance"
  , Header KindDescription haskellLang "D" "data type family"
  , Header KindDescription haskellLang "d" "data type family instance"
  , Header KindDescription haskellLang "I" "foreign import"
  , Header KindDescription haskellLang "E" "foreign export"
  ]
  where
    haskellLang = Just "Haskell"
