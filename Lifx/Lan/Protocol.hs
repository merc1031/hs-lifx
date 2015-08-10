module Lifx.Lan.Protocol
    ( Lan,
      GetService(..),
      serializeMsg,
      newState,
      newHdrAndCbDiscovery,
      runCallback,
      Bulb(..),
      newHdrAndCallback,
      sendMsg ) where

import Control.Applicative ( Applicative((<*>)), (<$>) )
import Control.Concurrent.STM
    ( STM, TArray, TVar, writeTVar, readTVar, newTVar, atomically )
import Data.Array.MArray ( writeArray, readArray, newListArray )
import Data.Binary
    ( Binary(..),
      putWord8,
      getWord8,
      encode,
      decodeOrFail )
import Data.Binary.Put ( putWord32le )
import Data.Binary.Get ( getWord32le )
import Data.Bits ( Bits((.&.)) )
import qualified Data.ByteString.Lazy as L
  ( ByteString, toChunks, append, length )
import Data.Int ( Int64 )
import Data.Word ( Word8, Word32, Word64 )
import Network.Socket ( Socket, SockAddr(SockAddrInet) )
import Network.Socket.ByteString ( sendManyTo )
import Text.Printf ( printf )

import Lifx.Lan.Util
import Lifx.Lan.Types

{- GetService and StateService are defined here instead of
 - Messages.hs for dependency reasons. -}

----------------------------------------------------------

data GetService = GetService

instance MessageType GetService where
  msgType _ = 2

instance Binary GetService where
  put _ = return ()
  get = return GetService

----------------------------------------------------------

data StateService
  = StateService
    { ssService :: !Word8
    , ssPort    :: !Word32
    } deriving Show

instance MessageType StateService where
  msgType _ = 3

instance Binary StateService where
  put x = do
    putWord8 $ ssService x
    putWord32le $ ssPort x

  get =
    StateService <$> getWord8 <*> getWord32le

----------------------------------------------------------

type Callback = Lan -> SockAddr -> Header -> L.ByteString -> IO ()

data Lan
  = Lan
    { stSeq :: TVar Word8
    , stSource :: !Word32
    , stCallbacks :: TArray Word8 Callback
    , stLog :: String -> IO ()
    , stSocket :: Socket
    }

instance Show Lan where
  show _ = "(Lan)"

newtype Target = Target Word64

instance Show Target where
  show (Target x) = colonize $ printf "%012X" (x .&. 0xffffffffffff)
    where colonize [c1, c2] = [c1, c2]
          -- mac address seems to be backwards
          colonize (c1:c2:rest) = colonize rest ++ [':', c1, c2]

data Bulb = Bulb Lan SockAddr Target deriving Show

serviceUDP = 1

serializeMsg :: (MessageType a, Binary a) => Header -> a -> L.ByteString
serializeMsg hdr payload = hdrBs `L.append` payloadBS
  where payloadBS = encode payload
        hsize = dfltHdrSize + L.length payloadBS
        hdr' = hdr { hdrType = msgType payload , hdrSize = fromIntegral hsize }
        hdrBs = encode hdr'

newState :: Word32 -> Socket -> Maybe (String -> IO ()) -> STM Lan
newState src sock logFunc = do
  seq <- newTVar 0
  cbacks <- newListArray (0, 255) (map noSeq [0..255])
  let lg = mkLogState logFunc
  return $ Lan { stSeq = seq
               , stSource = src
               , stCallbacks = cbacks
               , stLog = lg
               , stSocket = sock
               }
  where mkLogState Nothing = (\_ -> return ())
        mkLogState (Just f) = f
        noSeq i st sa _ _ =
          stLog st $ "No callback for sequence #" ++ show i ++ strFrom sa

newHdr :: Lan -> STM Header
newHdr st = do
  let seq = stSeq st
  n <- readTVar seq
  writeTVar seq (n + 1)
  return $ dfltHdr { hdrSource = stSource st , hdrSequence = n }

registerCallback :: Lan -> Header -> Callback -> STM ()
registerCallback st hdr cb =
  writeArray (stCallbacks st) (hdrSequence hdr) cb

-- resorted to this weird thing to fix type errors
contortedDecode :: Binary a => L.ByteString -> (a, Either String Int64)
contortedDecode bs =
  case decodeOrFail bs of
   Left ( _ , _ , msg ) -> ( undefined , Left msg )
   Right ( lftovr , _ , payload ) -> ( payload , Right (L.length lftovr) )

checkHeaderFields :: (MessageType a, Binary a)
                     => Header -> L.ByteString
                     -> Either String a
checkHeaderFields hdr bs =
  let (payload, decodeResult) = contortedDecode bs
      typ = hdrType hdr
      expected = msgType payload
  in if typ /= expected
     then Left $ "expected type " ++ show expected ++ " but got " ++ show typ
     else case decodeResult of
           Left msg -> Left msg
           Right lftovr
             | lftovr /= 0 -> Left $ show lftovr ++ " bytes left over"
             | otherwise -> Right payload

strFrom :: SockAddr -> String
strFrom sa = " (from " ++ show sa ++ ")"

wrapCallback :: (MessageType a, Binary a) => (Header -> a -> IO ()) -> Callback
wrapCallback cb st sa hdr bs = f $ checkHeaderFields hdr bs
  where f (Left msg) = stLog st $ msg ++ strFrom sa
        f (Right payload) = cb hdr payload

wrapStateService :: (Bulb -> IO ()) -> Callback
wrapStateService cb st sa hdr bs = f $ checkHeaderFields hdr bs
  where f (Left msg) = stLog st (msg ++ frm)
        f (Right payload) = bulb (ssService payload) (ssPort payload)
        frm = strFrom sa
        bulb serv port
          | serv /= serviceUDP = stLog st $ "service: expected "
                                 ++ show serviceUDP ++ " but got "
                                 ++ show serv ++ frm
          | otherwise = cb $ Bulb st (substPort sa port) (Target $ hdrTarget hdr)
        substPort (SockAddrInet _ ha) port = SockAddrInet (fromIntegral port) ha
        substPort other _ = other

wrapAndRegister :: (MessageType a, Binary a)
                   => Lan -> Header
                   -> (Header -> a -> IO ())
                   -> STM ()
wrapAndRegister st hdr cb = registerCallback st hdr $ wrapCallback cb

newHdrAndCallback :: (MessageType a, Binary a)
                     => Lan
                     -> (Header -> a -> IO ())
                     -> STM Header
newHdrAndCallback st cb = do
  hdr <- newHdr st
  wrapAndRegister st hdr cb
  return hdr

newHdrAndCbDiscovery :: Lan
                        -> (Bulb -> IO ())
                        -> STM Header
newHdrAndCbDiscovery st cb = do
  hdr <- newHdr st
  registerCallback st hdr $ wrapStateService cb
  return hdr

runCallback :: Lan -> SockAddr -> L.ByteString -> IO ()
runCallback st sa bs =
  case decodeOrFail bs of
   Left (_, _, msg) -> stLog st msg
   Right (bs', _, hdr) ->
     let hsz = fromIntegral (hdrSize hdr)
         len = L.length bs
         hsrc = hdrSource hdr
         ssrc = stSource st
         seq = hdrSequence hdr
         cbacks = stCallbacks st
         frm = strFrom sa
     in if hsz /= len
        then stLog st $ "length mismatch: " ++ show hsz
             ++ " ≠ " ++ show len ++ frm
        else if hsrc /= ssrc
             then stLog st $ "source mismatch: " ++ show hsrc
                  ++ " ≠ " ++ show ssrc ++ frm
             else runIt seq cbacks hdr bs'
  where runIt seq cbacks hdr bs' = do
          cb <- atomically $ readArray cbacks seq
          cb st sa hdr bs'

sendMsg :: (MessageType a, Binary a)
           => Bulb -> Header -> a
           -> IO ()
sendMsg (Bulb st sa (Target targ)) hdr payload =
  sendManyTo (stSocket st) (L.toChunks pkt) sa
  where hdr' = hdr { hdrTarget = targ }
        pkt = serializeMsg hdr' payload