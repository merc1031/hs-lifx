import Control.Applicative
import Control.Concurrent.STM
import Control.Monad
import Data.Array.MArray
import Data.Binary
import Data.Binary.Put
import Data.Binary.Get
import Data.Bits
import Data.ByteString.Lazy hiding (length, putStrLn, empty, map, take, replicate)
import qualified Data.ByteString.Lazy as L (length, take, replicate)
import Data.Char
import Data.Int
-- import Data.IntMap.Strict hiding (empty)
-- import qualified Data.IntMap.Strict as IM (empty)
import Data.ReinterpretCast
import Data.Word
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import Text.Printf

{- This is a combination of the parts called "Frame", "Frame Address",
   and "Protocol header" in the documentation:
   http://lan.developer.lifx.com/docs/header-description -}
data Header
  = Header
    { hdrSize        :: !Word16
    , hdrOrigin      :: !Word8
    , hdrTagged      :: !Bool
    , hdrAddressable :: !Bool
    , hdrProtocol    :: !Word16
    , hdrSource      :: !Word32
    , hdrTarget      :: !Word64
    -- , hdrReserved48  :: !Word64
    -- , hdrReserved6   :: !Word8
    , hdrAckRequired :: !Bool
    , hdrResRequired :: !Bool
    , hdrSequence    :: !Word8
    -- , hdrReserved64  :: !Word64
    , hdrType        :: !Word16
    -- , hdrReserved16  :: !Word16
    } deriving Show

dfltHdr = dh { hdrSize = fromIntegral $ L.length $ encode dh }
  where dh = Header { hdrSize = 0
                    , hdrOrigin = 0
                    , hdrTagged = False
                    , hdrAddressable = True
                    , hdrProtocol = 1024
                    , hdrSource = 91376
                    , hdrTarget = 0
                    , hdrAckRequired = False
                    , hdrResRequired = False
                    , hdrSequence = 0
                    , hdrType = 0
                    }

dfltHdrSize = L.length $ encode dfltHdr

bProtocol    = 0
bAddressable = 12
bTagged      = 13
bOrigin      = 14

bResRequired = 0
bAckRequired = 1

bounds :: (Integral a, Bits a, Show a) => String -> Int -> a -> Put
bounds name n val =
  when (val >= limit) $ fail (name ++ ": " ++ show val ++ " >= " ++ show limit)
  where limit = bit n

bitBool :: Bits a => Int -> Bool -> a
bitBool _ False = zeroBits
bitBool n True = bit n

extract :: (Integral a, Bits a, Integral b) => a -> Int -> Int -> b
extract x n w = fromIntegral field
  where field = (x `shiftR` n) .&. mask
        mask = (bit w) - 1

instance Binary Header where
  put h = do
    -- "Frame"
    putWord16le $ hdrSize h
    let hOrg = fromIntegral $ hdrOrigin h
        hTag = hdrTagged h
        hAdd = hdrAddressable h
        hPro = hdrProtocol h
    bounds "origin" 2 hOrg
    bounds "protocol" 12 hPro
    putWord16le $
      (hPro `shiftL` bProtocol) +
      bitBool bAddressable hAdd +
      bitBool bTagged hTag +
      (hOrg `shiftL` bOrigin)
    putWord32le $ hdrSource h
    -- "Frame Address"
    putWord64le $ hdrTarget h
    putWord32le 0 -- Reserved48
    putWord16le 0
    let hAck = hdrAckRequired h
        hRes = hdrResRequired h
    putWord8 $ bitBool bResRequired hRes + bitBool bAckRequired hAck
    putWord8 $ hdrSequence h
    -- "Protocol Header"
    putWord64le 0 -- Reserved64
    putWord16le $ hdrType h
    putWord16le 0 -- Reserved16

  get = do
    h <- Header <$> getWord16le -- hdrSize
    otap <- getWord16le
    let hh = h (extract otap bOrigin 2)
               (testBit otap bTagged)
               (testBit otap bAddressable)
               (extract otap bProtocol 12)
    hhh <- hh <$> getWord32le -- hdrSource
              <*> getWord64le -- hdrTarget
    getWord32le -- Reserved48
    getWord16le
    ar <- getWord8
    let hhhh = hhh (testBit ar bAckRequired) (testBit ar bResRequired)
    hhhhh <- hhhh <$> getWord8 -- hdrSequence
    getWord64le -- Reserved64
    hhhhhh <- hhhhh <$> getWord16le -- hdrType
    getWord16le -- Reserved16
    return hhhhhh

class MessageType t where
  msgType :: t -> Word16

data GetService = GetService

instance MessageType GetService where
  msgType _ = 2

instance Binary GetService where
  put _ = return ()
  get = return GetService

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

data GetHostInfo = GetHostInfo

instance MessageType GetHostInfo where
  msgType _ = 16 -- 12

instance Binary GetHostInfo where
  put _ = return ()
  get = return GetHostInfo

putFloat32le :: Float -> Put
putFloat32le f = putWord32le $ floatToWord f

getFloat32le :: Get Float
getFloat32le = wordToFloat <$> getWord32le

data StateHostInfo
  = StateHostInfo
    { shiSignal :: !Float
    , shiTX :: !Word32
    , shiRX :: !Word32
    , shiMcuTemperature :: !Word16 -- Int16; use fromIntegral
    } deriving Show

instance MessageType StateHostInfo where
  msgType _ = 17 -- 13

instance Binary StateHostInfo where
  put x = do
    putFloat32le $ shiSignal x
    putWord32le $ shiTX x
    putWord32le $ shiRX x
    putWord16le $ shiMcuTemperature x

  get =
    StateHostInfo <$> getFloat32le <*> getWord32le <*> getWord32le <*> getWord16le

data SetPower = SetPower { spLevel :: !Word16 }

instance MessageType SetPower where
  msgType _ = 21

instance Binary SetPower where
  put x = putWord16le $ spLevel x

  get = SetPower <$> getWord16le

data Acknowledgement = Acknowledgement

instance MessageType Acknowledgement where
  msgType _ = 45

instance Binary Acknowledgement where
  put _ = return ()
  get = return Acknowledgement

data GetLight = GetLight

instance MessageType GetLight where
  msgType _ = 101

instance Binary GetLight where
  put _ = return ()
  get = return GetLight

data HSBK =
  HSBK
  { hue :: !Word16
  , saturation :: !Word16
  , brightness :: !Word16
  , kelvin :: !Word16
  } deriving Show

instance Binary HSBK where
  put x = do
    putWord16le $ hue x
    putWord16le $ saturation x
    putWord16le $ brightness x
    putWord16le $ kelvin x

  get = HSBK <$> getWord16le <*> getWord16le <*> getWord16le <*> getWord16le

labelSize = 32

padByteString :: Int64 -> ByteString -> ByteString
padByteString goal bs = f (l `compare` goal)
  where l = L.length bs
        f LT = bs `append` pad
        f EQ = bs
        f GT = L.take goal bs
        pad = L.replicate (goal - l) (fromIntegral $ ord ' ')

data StateLight =
  StateLight
  { slColor :: HSBK
    -- Reserved16 (dim)
  , slPower :: !Word16
  , slLabel :: ByteString -- 32 bytes (aka labelSize)
    -- Reserved64 (tags)
  } deriving Show

instance MessageType StateLight where
  msgType _ = 107

instance Binary StateLight where
  put x = do
    put $ slColor x
    putWord16le 0 -- Reserved16 (dim)
    putWord16le $ slPower x
    putLazyByteString $ padByteString labelSize $ slLabel x
    putWord64le 0 -- Reserved64 (tags)

  get = do
    color <- get
    skip 2 -- Reserved16 (dim)
    power <- getWord16le
    label <- getLazyByteString labelSize
    skip 8 -- Reserved64 (tags)
    return $ StateLight color power label

data SetColor =
  SetColor
  { -- Reserved8 (stream)
    scColor :: HSBK
  , scDuration :: !Word32
  }

instance MessageType SetColor where
  msgType _ = 102

instance Binary SetColor where
  put x = do
    putWord8 0 -- Reserved8 (stream)
    put $ scColor x
    putWord32le $ scDuration x

  get = do
    skip 1 -- Reserved8 (stream)
    SetColor <$> get <*> getWord32le

data Waveform = Saw | Sine | HalfSine | Triangle | Pulse deriving (Show, Enum)

data SetWaveform =
  SetWaveform
  { -- Reserved8 (stream)
    swTransient :: !Bool
  , swColor :: HSBK
  , swPeriod :: !Word32
  , swCycles :: !Float
  , swSkewRatio :: !Word16
  , swWaveform :: Waveform
  } deriving Show

instance MessageType SetWaveform where
  msgType _ = 103

instance Binary SetWaveform where
  put x = do
    putWord8 0 -- Reserved8 (stream)
    putWord8 (if swTransient x then 1 else 0)
    put $ swColor x
    putWord32le $ swPeriod x
    putFloat32le $ swCycles x
    putWord16le $ swSkewRatio x
    putWord8 $ fromIntegral $ fromEnum $ swWaveform x

  get = do
    skip 1 -- Reserved8 (stream)
    t <- getWord8
    let trans = (t /= 0)
    x <- (SetWaveform trans) <$> get <*> getWord32le
         <*> getFloat32le <*> getWord16le
    w <- getWord8
    return (x $ toEnum $ fromIntegral w)

serializeMsg :: (MessageType a, Binary a) => Header -> a -> ByteString
serializeMsg hdr payload = hdrBs `append` payloadBS
  where payloadBS = encode payload
        hsize = dfltHdrSize + L.length payloadBS
        hdr' = hdr { hdrType = msgType payload , hdrSize = fromIntegral hsize }
        hdrBs = encode hdr'

type Callback = InternalState -> SockAddr -> Header -> ByteString -> IO ()

data InternalState
  = InternalState
    { stSeq :: TVar Word8
    , stSource :: !Word32
    , stCallbacks :: TArray Word8 Callback
    , stLog :: String -> IO ()
    , stSocket :: Socket
    }

instance Show InternalState where
  show _ = "(InternalState)"

newState :: Word32 -> Socket -> Maybe (String -> IO ()) -> STM InternalState
newState src sock logFunc = do
  seq <- newTVar 0
  cbacks <- newListArray (0, 255) (map noSeq [0..255])
  let lg = mkLogState logFunc
  return $ InternalState { stSeq = seq
                         , stSource = src
                         , stCallbacks = cbacks
                         , stLog = lg
                         , stSocket = sock
                         }
  where mkLogState Nothing = (\_ -> return ())
        mkLogState (Just f) = f
        noSeq i st sa _ _ =
          stLog st $ "No callback for sequence #" ++ show i ++ strFrom sa

newHdr :: InternalState -> STM Header
newHdr st = do
  let seq = stSeq st
  n <- readTVar seq
  writeTVar seq (n + 1)
  return $ dfltHdr { hdrSource = stSource st , hdrSequence = n }

registerCallback :: InternalState -> Header -> Callback -> STM ()
registerCallback st hdr cb =
  writeArray (stCallbacks st) (hdrSequence hdr) cb

-- resorted to this weird thing to fix type errors
contortedDecode :: Binary a => ByteString -> (a, Either String Int64)
contortedDecode bs =
  case decodeOrFail bs of
   Left ( _ , _ , msg ) -> ( undefined , Left msg )
   Right ( lftovr , _ , payload ) -> ( payload , Right (L.length lftovr) )

checkHeaderFields :: (MessageType a, Binary a)
                     => Header -> ByteString
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

serviceUDP = 1

newtype Target = Target Word64

instance Show Target where
  show (Target x) = colonize $ printf "%012X" (x .&. 0xffffffffffff)
    where colonize [c1, c2] = [c1, c2]
          -- mac address seems to be backwards
          colonize (c1:c2:rest) = colonize rest ++ [':', c1, c2]

data Bulb = Bulb InternalState SockAddr Target deriving Show

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
                   => InternalState -> Header
                   -> (Header -> a -> IO ())
                   -> STM ()
wrapAndRegister st hdr cb = registerCallback st hdr $ wrapCallback cb

newHdrAndCallback :: (MessageType a, Binary a)
                     => InternalState
                     -> (Header -> a -> IO ())
                     -> STM Header
newHdrAndCallback st cb = do
  hdr <- newHdr st
  wrapAndRegister st hdr cb
  return hdr

newHdrAndCbDiscovery :: InternalState
                        -> (Bulb -> IO ())
                        -> STM Header
newHdrAndCbDiscovery st cb = do
  hdr <- newHdr st
  registerCallback st hdr $ wrapStateService cb
  return hdr

runCallback :: InternalState -> SockAddr -> ByteString -> IO ()
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
  sendManyTo (stSocket st) (toChunks pkt) sa
  where hdr' = hdr { hdrTarget = targ }
        pkt = serializeMsg hdr' payload

doGetHostInfo :: Bulb -> (StateHostInfo -> IO ()) -> IO ()
doGetHostInfo bulb@(Bulb st _ _) cb = do
  hdr <- atomically $ newHdrAndCallback st (const cb)
  sendMsg bulb hdr GetHostInfo

doGetLight :: Bulb -> (StateLight -> IO ()) -> IO ()
doGetLight bulb @(Bulb st _ _) cb = do
  hdr <- atomically $ newHdrAndCallback st (const cb)
  sendMsg bulb hdr GetLight

needAck :: Header -> Header
needAck hdr = hdr { hdrAckRequired = True }

ackCb :: IO () -> Header -> Acknowledgement -> IO ()
ackCb cb hdr ack = cb

doSetPower :: Bulb -> Bool -> IO () -> IO ()
doSetPower bulb@(Bulb st _ _) pwr cb = do
  hdr <- atomically $ newHdrAndCallback st (ackCb cb)
  sendMsg bulb (needAck hdr) (SetPower $ f pwr)
  where f True = 0xffff
        f False = 0

doSetColor :: Bulb -> HSBK -> Word32 -> IO () -> IO ()
doSetColor bulb@(Bulb st _ _) color duration cb = do
  hdr <- atomically $ newHdrAndCallback st (ackCb cb)
  sendMsg bulb (needAck hdr) (SetColor color duration)

doSetWaveform :: Bulb -> SetWaveform -> IO () -> IO ()
doSetWaveform bulb@(Bulb st _ _) swf cb = do
  hdr <- atomically $ newHdrAndCallback st (ackCb cb)
  sendMsg bulb (needAck hdr) swf

myCb :: Bulb -> IO ()
myCb bulb = do
  putStrLn (show bulb)
  doGetHostInfo bulb $ \shi -> do
    putStrLn (show shi)
    doGetLight bulb $ \sl -> do
      putStrLn (show sl)
      doSetPower bulb True $ do
        -- doSetColor bulb (HSBK 0 65535 65535 9000) 10000 $ do
        let swf = SetWaveform True (HSBK 0 65535 65535 9000) 1000 10 32637 Sine
        doSetWaveform bulb swf $ do
          putStrLn "done!"

discovery :: InternalState -> STM ByteString
discovery st = do
  hdr <- newHdrAndCbDiscovery st myCb
  let hdr' = hdr { hdrTagged = True }
  return $ serializeMsg hdr' GetService

ethMtu = 1500

main = do
  putStrLn "Hello!"
  sock <- socket AF_INET Datagram defaultProtocol
  bind sock $ SockAddrInet aNY_PORT iNADDR_ANY
  when (isSupportedSocketOption Broadcast) (setSocketOption sock Broadcast 1)
  let flags = [ AI_NUMERICHOST , AI_NUMERICSERV ]
      myHints = defaultHints { addrFlags = flags }
  (ai:_ ) <- getAddrInfo (Just myHints) (Just "192.168.11.255") (Just "56700")
  let bcast = addrAddress ai
  st <- atomically $ newState 37619 sock (Just putStrLn)
  pkt <- atomically $ discovery st
  sendManyTo sock (toChunks pkt) bcast
  forever $ do
    (bs, sa) <- recvFrom sock ethMtu
    runCallback st sa $ fromStrict bs
  -- close sock
