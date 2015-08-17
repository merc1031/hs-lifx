module Lifx.Program.CmdParser where

import Data.Char
import Data.List
import Data.Text (Text)
import qualified Data.Text as T
import System.Console.CmdArgs.Explicit
import Text.Read

import Lifx.Program.Types


data LiteArgs =
  LiteArgs
  { aInterface :: Maybe Text
  , aTarget :: Selector
  , aCmd :: LiteCmd
  }

data LiteCmd = CmdList
             | CmdOn
             | CmdOff
             | CmdColor   ColorArg
             | CmdPulse   PulseArg
             | CmdBreathe PulseArg

data PulseArg =
  PulseArg
  { paColor     :: ColorArg
  , paFromColor :: ColorArg
  , paPeriod    :: LiFrac
  , paCycles    :: LiFrac
  , paPersist   :: Bool
  , paPowerOn   :: Bool
  , paPeak      :: LiFrac
  }

defPulseArg = PulseArg
  { paColor     = emptyColor
  , paFromColor = emptyColor
  , paPeriod    = 1.0
  , paCycles    = 1.0
  , paPersist   = False
  , paPowerOn   = True
  , paPeak      = 0.5
  }

defList :: LiteArgs
defList = LiteArgs { aInterface = Nothing, aTarget = SelAll, aCmd = CmdList }

defOn      = defList { aCmd = CmdOn }
defOff     = defList { aCmd = CmdOn }
defColor   = defList { aCmd = CmdColor   (CNamed White) }
defPulse   = defList { aCmd = CmdPulse   defPulseArg }
defBreathe = defList { aCmd = CmdBreathe defPulseArg }

gFlags = [iFlag]

iFlag = Flag
  { flagNames = ["i", "interface"]
  , flagInfo = FlagReq
  , flagValue = ifaceUpdate
  , flagType = "STRING"
  , flagHelp = "Name of network interface to use"
  }

ifaceUpdate :: String -> LiteArgs -> Either String LiteArgs
ifaceUpdate arg args = Right $ args { aInterface = T.pack arg }

cFlags = [hFlag, sFlag, bFlag, kFlag, nFlag]

-- TODO: 0-100 instead of 0.0-1.0?

hFlag = mkCFlag "hue"        "0-360"     (\c x -> c { hue = x })
sFlag = mkCFlag "saturation" "0.0-1.0"   (\c x -> c { saturation = x })
bFlag = mkCFlag "brightness" "0.0-1.0"   (\c x -> c { brightness = x })
kFlag = mkCFlag "kelvin"     "2500-9000" (\c x -> c { kelvin = x })

upcase :: String -> String
upcase = map toUpper

downcase :: String -> String
downcase = map toLower

capitalize :: String -> String
capitalize [] = []
capitalize (x:xs) = toUpper x : downcase xs

mkCFlag :: String -> String -> (MaybeColor -> Maybe LiFrac -> MaybeColor)
           -> Flag LiteArgs
mkCFlag name range f =
  flagReq [head name, name] (cflagUpdate f) "FLOAT"
  ("Set " ++ name ++ " of light's color (" ++ range ++ ")")

cflagUpdate :: (MaybeColor -> Maybe LiFrac -> MaybeColor)
               -> String
               -> LiteArgs
               -> Either String LiteArgs
cflagUpdate f arg args = do
  num <- readEither arg
  newCmd <- updColor (`f` Just num) (aCmd args)
  return $ args { aCmd = newCmd }

updColor :: (ColorArg -> ColorArg) -> LiteCmd -> Either String LiteCmd
updColor f (CmdColor c) = Right $ CCustom $ f $ customColor c
updColor f (CmdPulse p) = CmdPulse $ updPulseColor f p
updColor f (CmdBreathe p) = CmdPulse $ updPulseColor f p
updColor _ _ = Left "Color arguments not applicable to this command"

nFlag = flagReq ["n", "color"] updNamed "COLOR-NAME"
        ("Specify color by name (" ++ nameColors ++ ")")

nameColors = intercalate ", " $ map show colors
  where colors = (enumFromTo minBound maxBound) :: [NamedColor]

updNamed :: String -> LiteArgs -> Either String LiteArgs
updNamed arg args = do
  color <- readEither $ capitalize arg
  newCmd <- updColor (const $ CNamed color) (aCmd args)
  return $ args { aCmd = newCmd }

updPulseColor :: (ColorArg -> ColorArg) -> PulseArg -> PulseArg
updPulseColor f p = PulseArg { paColor = CCustom $ f $ customColor $ paColor p }

pFlags = cFlags ++ [pFlag, cFlag, tFlag, oFlag, eFlag]

pFlag = flagReq ["p", "period"] updPeriod "FLOAT" "Time of one cycle in seconds"
cFlag = flagReq ["c", "cycles"] updCycles "FLOAT" "Number of cycles"
tFlag = flagReq ["t", "persist"] updPersist "BOOL" "Remain with new color if true"
oFlag = flagReq ["o", "poweron"] updPowerOn "BOOL" "Power light on if currently off"
eFlag = flagReq ["e", "peak"] updPeak "FLOAT" "Is this different than duty cycle?"

updPeriod = updFrac (\n p -> p { paPeriod = n })
updCycles = updFrac (\n p -> p { paCycles = n })
updPersist = updBool (\b p -> p { paPersist = b })
updPowerOn = updBool (\b p -> p { paPowerOn = b })
updPeak = updFrac (\n p -> p { paPeak = n })

updFrac = updPulse id
updBool = updPulse capitalize

updPulse :: (a -> a)
            -> (a -> PulseArg -> PulseArg)
            -> String
            -> LiteArgs
            -> Either String LiteArgs
updPulse f1 f2 arg args = do
  x <- readEither (f1 arg)
  newCmd <- updPulse2 (f2 x) (aCmd args)
  return $ args { aCmd = newCmd }

updPulse2 :: (PulseArg -> PulseArg) LiteCmd
updPulse2 f (CmdPulse p) = CmdPulse (f p)
updPulse2 f (CmdBreathe p) = CmdBreathe (f p)
updPulse2 _ _ = Left "Pulse arguments not applicable to this command"

arguments :: Mode [(String, String)]
arguments =
  modes  "lifx"    defList  "Control LIFX light bulbs"
  [ mode "list"    defList  "List bulbs"        selArg gFlags
  , mode "on"      defOn    "Turn bulb on"      selArg gFlags
  , mode "off"     defOff   "Turn bulb off"     selArg gFlags
  , mode "color"   defColor "Set bulb color"    selArg $ gFlags ++ cFlags
  , mode "pulse"   defPulse "Square wave blink" selArg $ gFlags ++ pFlags
  , mode "breathe" defPulse "Sine wave blink"   selArg $ gFlags ++ pFlags
  ]