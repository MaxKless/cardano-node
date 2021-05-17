{-# LANGUAGE OverloadedStrings #-}

module Cardano.Logger.Handlers.Logs.Log
  ( logPrefix
  , logExtension
  , symLinkName
  , isItSymLink
  , doesSymLinkValid
  , isItLog
  , createLogAndSymLink
  , createLogAndUpdateSymLink
  , getTimeStampFromLog
  ) where

import qualified Data.ByteString.Lazy as LBS
import           Data.Maybe (isJust)
import           Data.Time (UTCTime, getCurrentTime)
import           Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import qualified Data.Text as T
import           System.Directory (createFileLink, doesFileExist, getSymbolicLinkTarget,
                                   pathIsSymbolicLink, renamePath, withCurrentDirectory)
import           System.FilePath ((</>), (<.>), takeBaseName, takeDirectory, takeFileName,
                                  takeExtension)

import           Cardano.Logger.Configuration

logPrefix :: String
logPrefix = "node-"

logExtension :: LogFormat -> String
logExtension AsText = ".log"
logExtension AsJSON = ".json"

symLinkName :: LogFormat -> FilePath
symLinkName format = "node" <.> logExtension format

symLinkNameTmp :: LogFormat -> FilePath
symLinkNameTmp format = symLinkName format <.> "tmp"

isItSymLink
  :: FilePath
  -> LogFormat
  -> IO Bool
isItSymLink fileName format =
  if takeFileName fileName == symLinkName format
    then pathIsSymbolicLink fileName
    else return False

doesSymLinkValid :: FilePath -> IO Bool
doesSymLinkValid pathToSymLink = do
  logName <- getSymbolicLinkTarget pathToSymLink
  -- Target log is always in the same subdir.
  let subDirForLogs = takeDirectory pathToSymLink
      pathToLog = subDirForLogs </> logName
  -- If the symlink is valid, 'pathToLog' does exist.
  doesFileExist pathToLog

isItLog :: LogFormat -> FilePath -> Bool
isItLog format pathToLog = hasProperPrefix && hasTimestamp && hasProperExt
  where
  fileName        = takeFileName pathToLog
  hasProperPrefix = T.pack logPrefix `T.isPrefixOf` T.pack fileName
  hasTimestamp    = isJust timeStamp
  timeStamp :: Maybe UTCTime
  timeStamp = parseTimeM True defaultTimeLocale timeStampFormat (T.unpack maybeTimestamp)
  maybeTimestamp  = T.drop (length logPrefix) . T.pack . takeBaseName $ fileName
  hasProperExt    = takeExtension fileName == logExtension format

-- | Create a new log file and symlink to it, from scratch.
createLogAndSymLink :: FilePath -> LogFormat -> IO ()
createLogAndSymLink subDirForLogs format = withCurrentDirectory subDirForLogs $
  createLog format >>= flip createFileLink (symLinkName format)

-- | Create a new log file and move existing symlink
-- from the old log file to the new one.
createLogAndUpdateSymLink :: FilePath -> LogFormat -> IO ()
createLogAndUpdateSymLink subDirForLogs format = withCurrentDirectory subDirForLogs $ do
  newLog <- createLog format
  let tmpSymLink  = symLinkNameTmp format
      realSymLink = symLinkName format
  createFileLink newLog tmpSymLink
  renamePath tmpSymLink realSymLink -- Atomic operation, uses POSIX.rename.

createLog :: LogFormat -> IO FilePath
createLog format = do
  ts <- formatTime defaultTimeLocale timeStampFormat <$> getCurrentTime
  let logName = logPrefix <> ts <.> logExtension format
  LBS.writeFile logName LBS.empty
  return logName

-- | This function is applied to the log we already checked,
-- so we definitely know it contains timestamp.
getTimeStampFromLog :: FilePath -> Maybe UTCTime
getTimeStampFromLog pathToLog =
  parseTimeM True defaultTimeLocale timeStampFormat timeStamp
 where
  timeStamp = drop (length logPrefix) . takeBaseName . takeFileName $ pathToLog

timeStampFormat :: String
timeStampFormat = "%Y-%m-%dT%H-%M-%S"
