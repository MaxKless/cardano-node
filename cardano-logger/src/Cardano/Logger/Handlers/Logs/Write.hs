{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Logger.Handlers.Logs.Write
  ( writeLogObjectsToFile
  ) where

import           Control.Exception (IOException, try)
import           Control.Monad (unless)
import           Data.Aeson (ToJSON, Value (..), (.=), object, toJSON)
import           Data.Aeson.Text (encodeToLazyText)
import qualified Data.ByteString.Lazy as LBS
import           Data.Char (isDigit)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import           Data.Text.Lazy.Encoding (encodeUtf8)
import           Data.Time.Clock (UTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           System.Directory (doesFileExist, createDirectoryIfMissing)
import           System.FilePath.Posix ((</>))
import           System.IO (hPutStrLn, stderr)

import           Cardano.BM.Data.LogItem

import           Cardano.Logger.Configuration
import           Cardano.Logger.Handlers.Logs.Log (createLogAndSymLink, symLinkName)
import           Cardano.Logger.Types (NodeId, NodeName)

writeLogObjectsToFile
  :: ToJSON a
  => NodeId
  -> NodeName
  -> FilePath
  -> LogFormat
  -> [LogObject a]
  -> IO ()
writeLogObjectsToFile nodeId nodeName rootDir format logObjects =
  try (createDirectoryIfMissing True subDirForLogs) >>= \case
    Left (e :: IOException) ->
      hPutStrLn stderr $ "Cannot create subdir for log files: " <> show e
    Right _ -> do
      symLinkIsHere <- doesFileExist pathToCurrentLog
      unless symLinkIsHere $
        createLogAndSymLink subDirForLogs format
      writeLogObjects pathToCurrentLog (loFormatter format) logObjects
 where
  subDirForLogs = rootDir </> nodeFullId
  nodeFullId = if T.null nodeName
                 then show nodeId
                 else T.unpack nodeName <> "-" <> show nodeId
  -- This is a symlink to the current log file, please see rotation parameters.
  pathToCurrentLog = subDirForLogs </> symLinkName format

  loFormatter AsText = loToText
  loFormatter AsJSON = loToJSON

  writeLogObjects logPath formatIt =
    -- It's much more efficiently to encode 'Text' explicitly and
    -- then perform 'ByteString'-level 'IO' than perform 'Text'-level 'IO'.
      LBS.appendFile logPath
    . encodeUtf8
    . TL.append nl
    . TL.intercalate nl
    . map formatIt

#if defined(mingw32_HOST_OS)
  nl = "\r\n"
#else
  nl = "\n"
#endif

loToText :: ToJSON a => LogObject a -> TL.Text
loToText (LogObject loname lometa loitem) =
  if TL.null msg
    then ""
    else "[" <> host <> name <> ":" <> sev <> ":" <> thId <> "] [" <> time <> "] " <> msg
 where
  host = if TL.null host' then "" else host' <> ":"
  host' = TL.fromStrict . hostname $ lometa
  name = TL.fromStrict loname
  sev = TL.pack . show . severity $ lometa
  thId = TL.filter isDigit (TL.pack . show . tid $ lometa)
  time = TL.pack . formatTime defaultTimeLocale "%F %T%2Q %Z" $ tstamp lometa
  msg =
    case loitem of
      (LogMessage logItem) ->
        case toJSON logItem of
          (String m) -> TL.fromStrict m
          m          -> encodeToLazyText m
      (LogError m) -> TL.fromStrict m
      (LogStructured o) -> encodeToLazyText o
      (LogStructuredText _o m) -> TL.fromStrict m
      (LogValue name' value) ->
        if T.null name'
          then TL.pack (show value)
          else TL.fromStrict name' <> " = " <> TL.pack (show value)
      (ObserveDiff _) -> encodeToLazyText loitem
      (ObserveOpen _) -> encodeToLazyText loitem
      (ObserveClose _) -> encodeToLazyText loitem
      (AggregatedMessage _) -> encodeToLazyText loitem
      (MonitoringEffect _) -> encodeToLazyText loitem
      KillPill -> ""
      Command _ -> ""

data LogObjectForJSON = LogObjectForJSON
  { jAt   :: !UTCTime
  , jNS   :: !T.Text
  , jData :: !Value
  , jHost :: !T.Text
  , jSev  :: !T.Text
  , jTId  :: !T.Text
  }

instance ToJSON LogObjectForJSON where
  toJSON LogObjectForJSON{..} =
    object [ "at"     .= formatTime defaultTimeLocale "%FT%T%2Q%Z" jAt
           , "ns"     .= jNS
           , "data"   .= jData
           , "host"   .= jHost
           , "sev"    .= jSev
           , "thread" .= jTId
           ]

loToJSON :: ToJSON a => LogObject a -> TL.Text
loToJSON (LogObject loname lometa loitem) = encodeToLazyText $
  LogObjectForJSON
    { jAt   = tstamp lometa
    , jNS   = loname
    , jData = toJSON loitem
    , jHost = hostname lometa
    , jSev  = T.pack . show . severity $ lometa
    , jTId  = T.filter isDigit (T.pack . show . tid $ lometa)
    }
