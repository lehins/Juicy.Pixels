{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- | Modules used for Bitmap file (.bmp) file loading and writing
module Codec.Picture.Bitmap( -- * Functions
                             writeBitmap
                           , encodeBitmap
                           , decodeBitmap
                           , encodeDynamicBitmap 
                           , writeDynamicBitmap 
                             -- * Accepted formt in output
                           , BmpEncodable( )
                           ) where
import Control.Monad( when, forM_ )
import Control.Monad.ST ( ST, runST )
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as M
import Data.Binary( Binary( .. ) )
import Data.Binary.Put( Put
                      , runPut
                      , putWord16le
                      , putWord32le
                      , putByteString 
                      )

import Data.Binary.Get( Get
                      , getWord16le 
                      , getWord32le
                      )

import Data.Word( Word32, Word16, Word8 )
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L

import Codec.Picture.InternalHelper
import Codec.Picture.Types
import Codec.Picture.VectorByteConversion

data BmpHeader = BmpHeader
    { magicIdentifier :: !Word16
    , fileSize        :: !Word32 -- ^ in bytes
    , reserved1       :: !Word16
    , reserved2       :: !Word16
    , dataOffset      :: !Word32
    }

bitmapMagicIdentifier :: Word16
bitmapMagicIdentifier = 0x4D42

instance Binary BmpHeader where
    put hdr = do
        putWord16le $ magicIdentifier hdr
        putWord32le $ fileSize hdr
        putWord16le $ reserved1 hdr
        putWord16le $ reserved2 hdr
        putWord32le $ dataOffset hdr

    get = do
        ident <- getWord16le
        when (ident /= bitmapMagicIdentifier)
             (fail "Invalid Bitmap magic identifier")
        fsize <- getWord32le
        r1 <- getWord16le
        r2 <- getWord16le
        offset <- getWord32le
        return BmpHeader
            { magicIdentifier = ident
            , fileSize = fsize
            , reserved1 = r1
            , reserved2 = r2
            , dataOffset = offset
            }


data BmpInfoHeader = BmpInfoHeader
    { size              :: !Word32 -- Header size in bytes
    , width             :: !Word32
    , height            :: !Word32
    , planes            :: !Word16 -- Number of colour planes
    , bitPerPixel       :: !Word16
    , bitmapCompression :: !Word32
    , byteImageSize     :: !Word32
    , xResolution       :: !Word32 -- ^ Pixels per meter
    , yResolution       :: !Word32 -- ^ Pixels per meter
    , colorCount        :: !Word32
    , importantColours  :: !Word32
    }

sizeofBmpHeader, sizeofBmpInfo  :: Word32
sizeofBmpHeader = 2 + 4 + 2 + 2 + 4
sizeofBmpInfo = 3 * 4 + 2 * 2 + 6 * 4

instance Binary BmpInfoHeader where
    put hdr = do
        putWord32le $ size hdr
        putWord32le $ width hdr
        putWord32le $ height hdr
        putWord16le $ planes hdr
        putWord16le $ bitPerPixel hdr
        putWord32le $ bitmapCompression hdr
        putWord32le $ byteImageSize hdr
        putWord32le $ xResolution hdr
        putWord32le $ yResolution hdr
        putWord32le $ colorCount hdr
        putWord32le $ importantColours hdr

    get = do
        readSize <- getWord32le
        readWidth <- getWord32le
        readHeight <- getWord32le
        readPlanes <- getWord16le
        readBitPerPixel <- getWord16le
        readBitmapCompression <- getWord32le
        readByteImageSize <- getWord32le
        readXResolution <- getWord32le
        readYResolution <- getWord32le
        readColorCount <- getWord32le
        readImportantColours <- getWord32le
        return BmpInfoHeader {
            size = readSize,
            width = readWidth,
            height = readHeight,
            planes = readPlanes,
            bitPerPixel = readBitPerPixel,
            bitmapCompression = readBitmapCompression,
            byteImageSize = readByteImageSize,
            xResolution = readXResolution,
            yResolution = readYResolution,
            colorCount = readColorCount,
            importantColours = readImportantColours
        }

newtype BmpPalette = BmpPalette [(Word8, Word8, Word8, Word8)]

putPalette :: BmpPalette -> Put
putPalette (BmpPalette p) = mapM_ (\(r, g, b, a) -> put r >> put g >> put b >> put a) p

-- | All the instance of this class can be written as a bitmap file
-- using this library.
class BmpEncodable pixel where
    bitsPerPixel   :: pixel -> Int
    bmpEncode      :: Image pixel -> Put
    defaultPalette :: pixel -> BmpPalette
    defaultPalette _ = BmpPalette []

stridePut :: M.STVector s Word8 -> Int -> Int -> ST s ()
{-# INLINE stridePut #-}
stridePut vec = inner
 where inner  _ 0 = return ()
       inner ix n = do
           (vec `M.unsafeWrite` ix) 0
           inner (ix + 1) (n - 1)

instance BmpEncodable Pixel8 where
    defaultPalette _ = BmpPalette [(x,x,x, 255) | x <- [0 .. 255]]
    bitsPerPixel _ = 8
    bmpEncode (Image {imageWidth = w, imageHeight = h, imageData = arr}) =
      forM_ [h - 1, h - 2 .. 0] $ \l -> putVector $ runST $ encodeLine l
        where stride = fromIntegral $ linePadding 8 w
              putVector vec = putByteString $ blitVector vec 0 lineWidth
              lineWidth = w + stride

              encodeLine line = do
                  buff <- M.new lineWidth

                  let lineIdx = line * w
                      inner col | col >= w = return ()
                      inner col = do
                          let v = (arr `V.unsafeIndex` (lineIdx + col))
                          (buff `M.unsafeWrite` col) v
                          inner (col + 1)

                  inner 0

                  stridePut buff w stride
                  V.unsafeFreeze buff

instance BmpEncodable PixelRGBA8 where
    bitsPerPixel _ = 32
    bmpEncode (Image {imageWidth = w, imageHeight = h, imageData = arr}) = 
      forM_ [h - 1, h - 2 .. 0] $ \l -> putVector $ runST $ putLine l
      where putVector vec = putByteString . blitVector vec 0 $ w * 4
            putLine line = do
                buff <- M.new $ 4 * w
                let initialIndex = line * w * 4
                    inner col _ _ | col >= w = return ()
                    inner col writeIdx readIdx = do
                        let r = arr `V.unsafeIndex` readIdx
                            g = arr `V.unsafeIndex` (readIdx + 1)
                            b = arr `V.unsafeIndex` (readIdx + 2)
                            a = arr `V.unsafeIndex` (readIdx + 3)

                        (buff `M.unsafeWrite` writeIdx) b
                        (buff `M.unsafeWrite` (writeIdx + 1)) g
                        (buff `M.unsafeWrite` (writeIdx + 2)) r
                        (buff `M.unsafeWrite` (writeIdx + 3)) a

                        inner (col + 1) (writeIdx + 4) (readIdx + 4)

                inner 0 0 initialIndex
                V.unsafeFreeze buff

instance BmpEncodable PixelRGB8 where
    bitsPerPixel _ = 24
    bmpEncode (Image {imageWidth = w, imageHeight = h, imageData = arr}) =
       forM_ [h - 1, h - 2 .. 0] $ \l -> putVector $ runST $ putLine l
        where stride = fromIntegral . linePadding 24 $ w
              putVector vec = putByteString $ blitVector vec 0 (w * 3 + stride)
              putLine line = do
                  buff <- M.new $ w * 3 + stride
                  let initialIndex = line * w * 3
                      inner col _ _ | col >= w = return ()
                      inner col writeIdx readIdx = do
                          let r = (arr `V.unsafeIndex` readIdx)
                              g = (arr `V.unsafeIndex` (readIdx + 1))
                              b = (arr `V.unsafeIndex` (readIdx + 2))
                          
                          (buff `M.unsafeWrite` writeIdx) b
                          (buff `M.unsafeWrite` (writeIdx + 1)) g
                          (buff `M.unsafeWrite` (writeIdx + 2)) r

                          inner (col + 1) (writeIdx + 3) (readIdx + 3)

                  inner 0 0 initialIndex
                  V.unsafeFreeze buff

decodeImageRGB8 :: BmpInfoHeader -> B.ByteString -> Image PixelRGB8
decodeImageRGB8 (BmpInfoHeader { width = w, height = h }) str = Image wi hi stArray
  where wi = fromIntegral w
        hi = fromIntegral h
        stArray = runST $ do
            arr <- M.new (fromIntegral $ w * h * 3)
            forM_ [hi - 1, hi - 2 .. 0] (readLine arr)
            V.unsafeFreeze arr

        stride = linePadding 24 wi
        readLine arr line =
            let readIndex = (wi * 3 + stride) * line
                lastIndex = wi * (hi - 1 - line + 1) * 3
                writeIndex = wi * (hi - 1 - line) * 3

                inner _ writeIdx | writeIdx >= lastIndex = return ()
                inner readIdx writeIdx = do
                    (arr `M.unsafeWrite`  writeIdx     ) (str `B.index` (readIdx + 2))
                    (arr `M.unsafeWrite` (writeIdx + 1)) (str `B.index` (readIdx + 1))
                    (arr `M.unsafeWrite` (writeIdx + 2)) (str `B.index`  readIdx)
                    inner (readIdx + 3) (writeIdx + 3)

            in inner readIndex writeIndex


-- | Try to decode a bitmap image.
-- Right now this function can output the following pixel types :
--
--    * PixelRGB8
--
decodeBitmap :: B.ByteString -> Either String DynamicImage
decodeBitmap str = flip runGetStrict str $ do
  _hdr      <- get :: Get BmpHeader
  bmpHeader <- get :: Get BmpInfoHeader
  case (bitPerPixel bmpHeader, planes  bmpHeader,
              bitmapCompression bmpHeader) of
    -- (32, 1, 0) -> {- ImageRGBA8 <$>-} fail "Meuh"
    (24, 1, 0) -> do
        rest <- getRemainingBytes
        return . ImageRGB8 $ decodeImageRGB8 bmpHeader rest
    _          -> fail "Can't handle BMP file"


-- | Write an image in a file use the bitmap format.
writeBitmap :: (BmpEncodable pixel)
            => FilePath -> Image pixel -> IO ()
writeBitmap filename img = L.writeFile filename $ encodeBitmap img

linePadding :: Int -> Int -> Int
linePadding bpp imgWidth = (4 - (bytesPerLine `mod` 4)) `mod` 4
    where bytesPerLine = imgWidth * (fromIntegral bpp `div` 8)

-- | Encode an image into a bytestring in .bmp format ready to be written
-- on disk.
encodeBitmap :: forall pixel. (BmpEncodable pixel) => Image pixel -> L.ByteString
encodeBitmap = encodeBitmapWithPalette (defaultPalette (undefined :: pixel))


-- | Write a dynamic image in a .bmp image file if possible.
-- The same restriction as encodeDynamicBitmap apply.
writeDynamicBitmap :: FilePath -> DynamicImage -> IO (Either String Bool)
writeDynamicBitmap path img = case encodeDynamicBitmap img of
        Left err -> return $ Left err
        Right b  -> L.writeFile path b >> return (Right True)

-- | Encode a dynamic image in bmp if possible, supported pixel type are :
--
--   - RGB8
--
--   - RGBA8
--
--   - Y8
--
encodeDynamicBitmap :: DynamicImage -> Either String L.ByteString
encodeDynamicBitmap (ImageRGB8 img) = Right $ encodeBitmap img
encodeDynamicBitmap (ImageRGBA8 img) = Right $ encodeBitmap img
encodeDynamicBitmap (ImageY8 img) = Right $ encodeBitmap img
encodeDynamicBitmap _ = Left "Unsupported image format for bitmap export"


-- | Convert an image to a bytestring ready to be serialized.
encodeBitmapWithPalette :: forall pixel. (BmpEncodable pixel)
                        => BmpPalette -> Image pixel -> L.ByteString
encodeBitmapWithPalette pal@(BmpPalette palette) img =
  runPut $ put hdr >> put info >> putPalette pal >> bmpEncode img
    where imgWidth = fromIntegral $ imageWidth img
          imgHeight = fromIntegral $ imageHeight img

          paletteSize = fromIntegral $ length palette
          bpp = bitsPerPixel (undefined :: pixel)
          padding = linePadding bpp (imgWidth + 1)
          imagePixelSize = fromIntegral $ (imgWidth + padding) * imgHeight * 4
          hdr = BmpHeader {
              magicIdentifier = bitmapMagicIdentifier,
              fileSize = sizeofBmpHeader + sizeofBmpInfo + 4 * paletteSize + imagePixelSize,
              reserved1 = 0,
              reserved2 = 0,
              dataOffset = sizeofBmpHeader + sizeofBmpInfo + 4 * paletteSize
          }

          info = BmpInfoHeader {
              size = sizeofBmpInfo,
              width = fromIntegral imgWidth,
              height = fromIntegral imgHeight,
              planes = 1,
              bitPerPixel = fromIntegral bpp,
              bitmapCompression = 0, -- no compression
              byteImageSize = imagePixelSize,
              xResolution = 0,
              yResolution = 0,
              colorCount = 0,
              importantColours = paletteSize
          }

