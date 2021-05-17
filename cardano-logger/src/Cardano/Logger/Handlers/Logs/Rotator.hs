{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logger.Handlers.Logs.Rotator
  ( runLogsRotator
  ) where

import           Control.Exception.Safe (Exception (..), catchIO)
import           Control.Concurrent (threadDelay)
import           Control.Concurrent.Async (forConcurrently_)
import           Control.Monad (filterM, forever, when)
import           Data.List (nub, sort)
import           Data.Time (diffUTCTime, getCurrentTime)
import           Data.Word (Word64)
import           System.Directory (doesDirectoryExist, getFileSize, createFileLink,
                                   listDirectory, removeFile)
import           System.FilePath ((</>), takeDirectory)
import           System.IO (hPutStrLn, stderr)

import           Cardano.Logger.Configuration
import           Cardano.Logger.Handlers.Logs.Log

runLogsRotator :: LoggerConfig -> IO ()
runLogsRotator LoggerConfig{..} =
  case rotation of
    Nothing -> return () -- No rotation parameters are defined.
    Just rotParams -> launchRotator rotParams rootDirsWithFormats
 where
  rootDirsWithFormats = nub . map getRootAndFormat . filter fileParamsOnly $ logging
  fileParamsOnly   LoggingParams{..} = logMode == FileMode
  getRootAndFormat LoggingParams{..} = (logRoot, logFormat)

-- | All the logs with 'LogObject's received from particular node
-- will be stored in a separate directory, so they can be checked
-- concurrently.
launchRotator
  :: RotationParams
  -> [(FilePath, LogFormat)]
  -> IO ()
launchRotator _ [] = return ()
launchRotator rotParams rootDirsWithFormats = forever $ do
  forConcurrently_ rootDirsWithFormats $ checkRootDir rotParams
  threadDelay 20000000

checkRootDir
  :: RotationParams
  -> (FilePath, LogFormat)
  -> IO ()
checkRootDir rotParams (rootDir, format) =
  catchIO checkLogsInRootDir' $ \e ->
    hPutStrLn stderr $ "Cannot write log items to file: " <> displayException e
 where
  checkLogsInRootDir' =
    listDirectory rootDir >>= \case
      [] ->
        -- There are no nodes' subdirs yet (or they were deleted),
        -- so no rotation can be performed.
        return ()
      maybeSubDirs ->
        -- All the logs received from particular node will be stored in a subdir.
        filterM doesDirectoryExist maybeSubDirs >>= \case
          [] ->
            -- There are no subdirs with logs here, so no rotation can be performed.
            return ()
          subDirs -> do
            let fullPathsToSubDirs = map ((</>) rootDir) subDirs
            forConcurrently_ fullPathsToSubDirs $ checkLogsFromNode rotParams format

checkLogsFromNode
  :: RotationParams
  -> LogFormat
  -> FilePath
  -> IO ()
checkLogsFromNode rotParams format subDirForLogs =
  listDirectory subDirForLogs >>= \case
    [] ->
      -- There are no logs in this subdir (probably they were deleted),
      -- so no rotation can be performed.
      return ()
    [oneFile] ->
      -- At least two files must be there: one log and symlink.
      -- So if there is only one file, it's a weird situation,
      -- (probably invalid symlink only), we have to try to fix it.
      fixLog (subDirForLogs </> oneFile) format
    logs -> do
      let fullPathsToLogs = map ((</>) subDirForLogs) logs
      checkLogs rotParams format fullPathsToLogs

fixLog
  :: FilePath
  -> LogFormat
  -> IO ()
fixLog oneFile format =
  isItSymLink oneFile format >>= \case
    True -> do
      -- It is a single symlink, but corresponding log was deleted.
      removeFile oneFile
      createLogAndSymLink (takeDirectory oneFile) format
    False ->
      when (isItLog format oneFile) $
        -- It is a single log, but its symlink was deleted.
        createFileLink oneFile $ symLinkName format

checkLogs
  :: RotationParams
  -> LogFormat
  -> [FilePath]
  -> IO ()
checkLogs RotationParams{..} format logs = do
  -- Since the names of the logs starts with the same name and
  -- contain timestamp, we can sort them so the earliest log will
  -- always be the first one and the latest one will be the last one.
  let logsWeNeed = sort . filter (isItLog format) $ logs
  checkIfCurrentLogIsFull logsWeNeed format rpLogLimitBytes
  checkIfThereAreOldLogs logsWeNeed format rpMaxAgeHours rpKeepFilesNum

checkIfCurrentLogIsFull
  :: [FilePath]
  -> LogFormat
  -> Word64
  -> IO ()
checkIfCurrentLogIsFull [] _ _ = return ()
checkIfCurrentLogIsFull logs format maxSizeInBytes = do
  itIsFull <- isItFull currentLog
  when itIsFull $ do
    let subDirForLogs = takeDirectory $ head logs -- All these logs are in the same subdir.
    createLogAndUpdateSymLink subDirForLogs format
 where
  currentLog = last logs -- Log we're writing in, via symlink.
  isItFull logName = do
    logSize <- getFileSize logName
    return $ fromIntegral logSize >= maxSizeInBytes

checkIfThereAreOldLogs
  :: [FilePath]
  -> LogFormat
  -> Word
  -> Word
  -> IO ()
checkIfThereAreOldLogs [] _ _ _ = return ()
checkIfThereAreOldLogs logs format maxAgeInHours keepFilesNum = do
  now <- getCurrentTime
  let oldLogs = filter (oldLog now) logs
      remainingLogsNum = length logs - length oldLogs
  if remainingLogsNum >= fromIntegral keepFilesNum
    then removeAllOldLogs  oldLogs remainingLogsNum
    else removeSomeOldLogs oldLogs remainingLogsNum
 where
  oldLog now' logName =
    case getTimeStampFromLog logName of
      Just timeStamp ->
        let logAge = now' `diffUTCTime` timeStamp
        in toSeconds logAge >= maxAgeInSecs
      Nothing -> False

  maxAgeInSecs = fromIntegral maxAgeInHours * 3600
  toSeconds age = fromEnum age `div` 1000000000000

  removeAllOldLogs [] _ = return ()
  removeAllOldLogs oldLogs remainingLogsNum = do
    mapM_ removeFile oldLogs
    -- We removed all old logs, but there is a possible situation
    -- when 'keepFilesNum' is 0 (user doesn't want to keep any old logs)
    -- and remainingLogsNum is 0 (because all the logs were old).
    -- But in this case our symlink is invalid now, because we removed
    -- the current log as well.
    when (remainingLogsNum == 0) $ do
      let subDirForLogs = takeDirectory $ head oldLogs -- All these logs are in the same subdir.
      removeFile $ subDirForLogs </> symLinkName format
      createLogAndSymLink subDirForLogs format

  removeSomeOldLogs [] _ = return ()
  removeSomeOldLogs oldLogs remainingLogsNum = do
    -- Too many logs are old, so make sure we keep enough latest logs.
    let oldLogsNumToKeep = fromIntegral keepFilesNum - remainingLogsNum
    -- Reverse logs to place the latest ones in the beginning and drop
    -- 'oldLogsNumToKeep' to keep them.
    let oldLogsToRemove = drop oldLogsNumToKeep . reverse $ oldLogs
    -- If the total num of old logs is less than 'keepFilesNum', all
    -- of them will be kept.
    mapM_ removeFile oldLogsToRemove
