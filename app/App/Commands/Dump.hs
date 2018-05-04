{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module App.Commands.Dump where

import App.Commands.Options.Type
import Arbor.File.Format.Asif
import Arbor.File.Format.Asif.Data.Ip
import Arbor.File.Format.Asif.IO
import Arbor.File.Format.Asif.Whatever
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class          (liftIO)
import Control.Monad.Trans.Resource    (MonadResource, runResourceT)
import Data.Char                       (isPrint)
import Data.Function
import Data.List
import Data.Monoid
import Data.Text                       (Text)
import Data.Thyme.Clock
import Data.Thyme.Clock.POSIX          (POSIXTime, getPOSIXTime)
import Data.Thyme.Format               (formatTime)
import Data.Thyme.Time.Core
import Data.Word
import HaskellWorks.Data.Bits.BitShow
import Numeric                         (showHex)
import Options.Applicative
import System.Directory
import System.Locale                   (defaultTimeLocale, iso8601DateFormat)
import Text.Printf

import qualified App.Commands.Options.Lens              as L
import qualified Arbor.File.Format.Asif.ByteString.Lazy as LBS
import qualified Arbor.File.Format.Asif.Format          as F
import qualified Arbor.File.Format.Asif.IO              as MIO
import qualified Arbor.File.Format.Asif.Lens            as L
import qualified Data.Attoparsec.ByteString             as AP
import qualified Data.Binary                            as G
import qualified Data.Binary.Get                        as G
import qualified Data.ByteString                        as BS
import qualified Data.ByteString.Lazy                   as LBS
import qualified Data.ByteString.Lazy.Char8             as LBSC
import qualified Data.Map                               as M
import qualified Data.Text                              as T
import qualified Data.Text.Encoding                     as T
import qualified Data.Vector.Storable                   as DVS
import qualified System.Directory                       as IO
import qualified System.IO                              as IO

{-# ANN module ("HLint: ignore Reduce duplication"  :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"        :: String) #-}

parseDumpOptions :: Parser DumpOptions
parseDumpOptions = DumpOptions
  <$> strOption
      (   long "source"
      <>  metavar "FILE"
      <>  value "-"
      <>  help "Input file"
      )
  <*> strOption
      (   long "target"
      <>  metavar "FILE"
      <>  value "-"
      <>  help "Output file"
      )

commandDump :: Parser (IO ())
commandDump = runResourceT . runDump <$> parseDumpOptions

showTime :: FormatTime t => t -> String
showTime = formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S %Z"))

runDump :: MonadResource m => DumpOptions -> m ()
runDump opt = do
  (_, hIn) <- openFileOrStd (opt ^. L.source) IO.ReadMode
  (_, hOut) <- openFileOrStd (opt ^. L.target) IO.WriteMode

  contents <- liftIO $ LBS.hGetContents hIn

  case extractNamedSegments magic contents of
    Left error -> do
      liftIO $ IO.hPutStrLn IO.stderr $ "Error occured: " <> error
      return ()
    Right namedSegments -> do
      forM_ (M.toList namedSegments) $ \(path, segment) -> do
        liftIO $ IO.hPutStrLn hOut $ "==== " <> T.unpack path <> " ===="

        case segment ^. L.meta . L.format of
          Just (Known F.StringZ) ->
            forM_ (init (LBS.split 0 (segment ^. L.payload))) $ \bs ->
              liftIO $ IO.hPutStrLn hOut $ T.unpack (T.decodeUtf8 (LBS.toStrict bs))
          Just (Known (F.Repeat n F.Char)) ->
            forM_ (LBS.chunkBy (fromIntegral n) (segment ^. L.payload)) $ \bs ->
              liftIO $ IO.hPutStrLn hOut $ T.unpack (T.decodeUtf8 (LBS.toStrict bs))
          Just (Known F.TimeMillis64LE) ->
            forM_ (LBS.chunkBy 8 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt64le (LBS.take 8 (bs <> LBS.replicate 8 0))
              let t :: POSIXTime = (w `div` 1000) ^. from microseconds
              liftIO $ IO.hPutStrLn hOut $ showTime (posixSecondsToUTCTime t) <> " (" <> show w <> " ms)"
          Just (Known F.TimeMicros64LE) ->
            forM_ (LBS.chunkBy 8 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt64le (LBS.take 8 (bs <> LBS.replicate 8 0))
              let t :: POSIXTime = w ^. from microseconds
              liftIO $ IO.hPutStrLn hOut $ showTime (posixSecondsToUTCTime t) <> " (" <> show w <> " µs)"
          Just (Known F.Ipv4) ->
            forM_ (LBS.chunkBy 4 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getWord32le (LBS.take 8 (bs <> LBS.replicate 4 0))
              let ipString = w & word32ToIpv4 & ipv4ToString
              liftIO $ IO.hPutStrLn hOut $ ipString <> replicate (16 - length ipString) ' ' <> "(" <> show w <> ")"
          Just (Known F.Int64LE) ->
            forM_ (LBS.chunkBy 8 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt64le (LBS.take 8 (bs <> LBS.replicate 8 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Int32LE) ->
            forM_ (LBS.chunkBy 4 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt32le (LBS.take 4 (bs <> LBS.replicate 4 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Int16LE) ->
            forM_ (LBS.chunkBy 2 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt16le (LBS.take 2 (bs <> LBS.replicate 2 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Int8) ->
            forM_ (LBS.chunkBy 1 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getInt8 (LBS.take 1 (bs <> LBS.replicate 1 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Word64LE) ->
            forM_ (LBS.chunkBy 8 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getWord64le (LBS.take 8 (bs <> LBS.replicate 8 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Word32LE) ->
            forM_ (LBS.chunkBy 4 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getWord32le (LBS.take 4 (bs <> LBS.replicate 4 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Word16LE) ->
            forM_ (LBS.chunkBy 2 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getWord16le (LBS.take 2 (bs <> LBS.replicate 2 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Word8) ->
            forM_ (LBS.chunkBy 1 (segment ^. L.payload)) $ \bs -> do
              let w = G.runGet G.getWord8 (LBS.take 1 (bs <> LBS.replicate 1 0))
              liftIO $ IO.hPrint hOut w
          Just (Known F.Text) ->
            liftIO $ LBSC.hPutStrLn hOut (segment ^. L.payload)
          Just (Known F.BitString) ->
            liftIO $ IO.hPutStrLn hOut (bitShow (segment ^. L.payload))
          _ ->
            forM_ (zip (LBS.chunkBy 16 (segment ^. L.payload)) [0, 16..]) $ \(bs, i) -> do
              let bytes = mconcat (intersperse " " (reverse . take 2 . reverse . ('0':) . flip showHex "" <$> LBS.unpack bs))
              liftIO $ IO.hPutStr hOut $ reverse $ take 8 $ reverse $ ("0000000" ++) $ showHex i ""
              liftIO $ IO.hPutStr hOut "  "
              liftIO $ IO.hPutStr hOut $ bytes <> replicate (47 - length bytes) ' '
              liftIO $ IO.hPutStr hOut "  "
              liftIO $ IO.hPutStr hOut $ (\c -> if isPrint c then c else '.') <$> LBSC.unpack bs
              liftIO $ IO.hPutStrLn hOut ""

  where magic = AP.string "seg:" *> (BS.pack <$> many AP.anyWord8) AP.<?> "\"seg:????\""
