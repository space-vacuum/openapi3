{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}
-- Generic a is redundant in  ToParamSchema a default imple
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
-- For TypeErrors
{-# OPTIONS_GHC -Wno-unticked-promoted-constructors #-}
module Data.OpenApi.Internal.ParamSchema where

import Control.Lens
import Data.Aeson (ToJSON (..))
import Data.Proxy
import GHC.Generics

import Data.Int
import "unordered-containers" Data.HashSet (HashSet)
import Data.Monoid
import Data.Set (Set)
import Data.Scientific
import Data.Fixed (HasResolution(..), Fixed, Pico)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Time
import qualified Data.Vector as V
import qualified Data.Vector.Primitive as VP
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Unboxed as VU
import Data.Version (Version)
import Numeric.Natural.Compat (Natural)
import Data.Word
import Data.UUID.Types (UUID)
import Web.Cookie (SetCookie)

import Data.OpenApi.Internal
import Data.OpenApi.Lens
import Data.OpenApi.SchemaOptions

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import GHC.TypeLits (TypeError, ErrorMessage(..))

-- | Default schema for binary data (any sequence of octets).
binarySchema :: Schema
binarySchema = mempty
  & type_ ?~ OpenApiString
  & format ?~ "binary"

-- | Default schema for binary data (base64 encoded).
byteSchema :: Schema
byteSchema = mempty
  & type_ ?~ OpenApiString
  & format ?~ "byte"

-- | Default schema for password string.
-- @"password"@ format is used to hint UIs the input needs to be obscured.
passwordSchema :: Schema
passwordSchema = mempty
  & type_ ?~ OpenApiString
  & format ?~ "password"

-- | Convert a type into a plain @'Schema'@.
--
-- In previous versions of the package there was a separate type called @ParamSchema@, which was
-- included in a greater 'Schema'. Now this is a single class, but distinction for schema generators
-- for "simple" types is preserved.
--
-- 'ToParamSchema' is suited only for primitive-like types without nested fields and such.
--
-- An example type and instance:
--
-- @
-- {-\# LANGUAGE OverloadedStrings \#-}   -- allows to write 'T.Text' literals
--
-- import Control.Lens
--
-- data Direction = Up | Down
--
-- instance ToParamSchema Direction where
--   toParamSchema _ = mempty
--      & type_ ?~ OpenApiString
--      & enum_ ?~ [ \"Up\", \"Down\" ]
-- @
--
-- Instead of manually writing your @'ToParamSchema'@ instance you can
-- use a default generic implementation of @'toParamSchema'@.
--
-- To do that, simply add @deriving 'Generic'@ clause to your datatype
-- and declare a @'ToParamSchema'@ instance for your datatype without
-- giving definition for @'toParamSchema'@.
--
-- For instance, the previous example can be simplified into this:
--
-- @
-- {-\# LANGUAGE DeriveGeneric \#-}
--
-- import GHC.Generics (Generic)
--
-- data Direction = Up | Down deriving Generic
--
-- instance ToParamSchema Direction
-- @
class ToParamSchema a where
  -- | Convert a type into a plain parameter schema.
  --
  -- >>> BSL.putStrLn $ encodePretty $ toParamSchema (Proxy :: Proxy Integer)
  -- {
  --     "type": "integer"
  -- }
  toParamSchema :: Proxy a -> Schema
  default toParamSchema :: (Generic a, GToParamSchema (Rep a)) => Proxy a -> Schema
  toParamSchema = genericToParamSchema defaultSchemaOptions

instance {-# OVERLAPPING #-} ToParamSchema String where
  toParamSchema _ = mempty & type_ ?~ OpenApiString

instance ToParamSchema Bool where
  toParamSchema _ = mempty & type_ ?~ OpenApiBoolean

instance ToParamSchema Integer where
  toParamSchema _ = mempty & type_ ?~ OpenApiInteger

instance ToParamSchema Natural where
  toParamSchema _ = mempty
    & type_            ?~ OpenApiInteger
    & minimum_         ?~ 0
    & exclusiveMinimum ?~ False

instance ToParamSchema Int    where toParamSchema = toParamSchemaBoundedIntegral
instance ToParamSchema Int8   where toParamSchema = toParamSchemaBoundedIntegral
instance ToParamSchema Int16  where toParamSchema = toParamSchemaBoundedIntegral

instance ToParamSchema Int32 where
  toParamSchema proxy = toParamSchemaBoundedIntegral proxy & format ?~ "int32"

instance ToParamSchema Int64 where
  toParamSchema proxy = toParamSchemaBoundedIntegral proxy & format ?~ "int64"

instance ToParamSchema Word   where toParamSchema = toParamSchemaBoundedIntegral
instance ToParamSchema Word8  where toParamSchema = toParamSchemaBoundedIntegral
instance ToParamSchema Word16 where toParamSchema = toParamSchemaBoundedIntegral

instance ToParamSchema Word32 where
  toParamSchema proxy = toParamSchemaBoundedIntegral proxy & format ?~ "int32"

instance ToParamSchema Word64 where
  toParamSchema proxy = toParamSchemaBoundedIntegral proxy & format ?~ "int64"

-- | Default plain schema for @'Bounded'@, @'Integral'@ types.
--
-- >>> BSL.putStrLn $ encodePretty $ toParamSchemaBoundedIntegral (Proxy :: Proxy Int8)
-- {
--     "maximum": 127,
--     "minimum": -128,
--     "type": "integer"
-- }
toParamSchemaBoundedIntegral :: forall a t. (Bounded a, Integral a) => Proxy a -> Schema
toParamSchemaBoundedIntegral _ = mempty
  & type_ ?~ OpenApiInteger
  & minimum_ ?~ fromInteger (toInteger (minBound :: a))
  & maximum_ ?~ fromInteger (toInteger (maxBound :: a))

instance ToParamSchema Char where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiString
    & maxLength ?~ 1
    & minLength ?~ 1

instance ToParamSchema Scientific where
  toParamSchema _ = mempty & type_ ?~ OpenApiNumber

instance HasResolution a => ToParamSchema (Fixed a) where
  toParamSchema _ = mempty
    & type_      ?~ OpenApiNumber
    & multipleOf ?~ (recip . fromInteger $ resolution (Proxy :: Proxy a))

instance ToParamSchema Double where
  toParamSchema _ = mempty
    & type_  ?~ OpenApiNumber
    & format ?~ "double"

instance ToParamSchema Float where
  toParamSchema _ = mempty
    & type_  ?~ OpenApiNumber
    & format ?~ "float"

timeParamSchema :: String -> Schema
timeParamSchema fmt = mempty
  & type_  ?~ OpenApiString
  & format ?~ T.pack fmt

-- | Format @"date"@ corresponds to @yyyy-mm-dd@ format.
instance ToParamSchema Day where
  toParamSchema _ = timeParamSchema "date"

-- |
-- >>> toParamSchema (Proxy :: Proxy TimeOfDay) ^. format
-- Just "hh:MM:ss"
instance ToParamSchema TimeOfDay where
  toParamSchema _ = timeParamSchema "hh:MM:ss"

-- |
-- >>> toParamSchema (Proxy :: Proxy LocalTime) ^. format
-- Just "yyyy-mm-ddThh:MM:ss"
instance ToParamSchema LocalTime where
  toParamSchema _ = timeParamSchema "yyyy-mm-ddThh:MM:ss"

-- |
-- >>> toParamSchema (Proxy :: Proxy ZonedTime) ^. format
-- Just "date-time"
instance ToParamSchema ZonedTime where
  toParamSchema _ = timeParamSchema "date-time"

-- |
-- >>> toParamSchema (Proxy :: Proxy UTCTime) ^. format
-- Just "yyyy-mm-ddThh:MM:ssZ"
instance ToParamSchema UTCTime where
  toParamSchema _ = timeParamSchema "yyyy-mm-ddThh:MM:ssZ"

instance ToParamSchema NominalDiffTime where
  toParamSchema _ = toParamSchema (Proxy :: Proxy Pico)

instance ToParamSchema T.Text where
  toParamSchema _ = toParamSchema (Proxy :: Proxy String)

instance ToParamSchema TL.Text where
  toParamSchema _ = toParamSchema (Proxy :: Proxy String)

instance ToParamSchema Version where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiString
    & pattern ?~ "^\\d+(\\.\\d+)*$"

instance ToParamSchema SetCookie where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiString

type family ToParamSchemaByteStringError bs where
  ToParamSchemaByteStringError bs = TypeError
      ( 'Text "Impossible to have an instance " :<>: ShowType (ToParamSchema bs) :<>: Text "."
   :$$: 'Text "Please, use a newtype wrapper around " :<>: ShowType bs :<>: Text " instead."
   :$$: 'Text "Consider using byteParamSchema or binaryParamSchemaemplates." )

instance ToParamSchemaByteStringError BS.ByteString  => ToParamSchema BS.ByteString  where toParamSchema = error "impossible"
instance ToParamSchemaByteStringError BSL.ByteString => ToParamSchema BSL.ByteString where toParamSchema = error "impossible"

instance ToParamSchema All where toParamSchema _ = toParamSchema (Proxy :: Proxy Bool)
instance ToParamSchema Any where toParamSchema _ = toParamSchema (Proxy :: Proxy Bool)
instance ToParamSchema a => ToParamSchema (Sum a)     where toParamSchema _ = toParamSchema (Proxy :: Proxy a)
instance ToParamSchema a => ToParamSchema (Product a) where toParamSchema _ = toParamSchema (Proxy :: Proxy a)
instance ToParamSchema a => ToParamSchema (First a)   where toParamSchema _ = toParamSchema (Proxy :: Proxy a)
instance ToParamSchema a => ToParamSchema (Last a)    where toParamSchema _ = toParamSchema (Proxy :: Proxy a)
instance ToParamSchema a => ToParamSchema (Dual a)    where toParamSchema _ = toParamSchema (Proxy :: Proxy a)

instance ToParamSchema a => ToParamSchema (Identity a) where toParamSchema _ = toParamSchema (Proxy :: Proxy a)

instance ToParamSchema a => ToParamSchema [a] where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiArray
    & items ?~ OpenApiItemsObject (Inline $ toParamSchema (Proxy :: Proxy a))

instance ToParamSchema a => ToParamSchema (V.Vector a) where toParamSchema _ = toParamSchema (Proxy :: Proxy [a])
instance ToParamSchema a => ToParamSchema (VP.Vector a) where toParamSchema _ = toParamSchema (Proxy :: Proxy [a])
instance ToParamSchema a => ToParamSchema (VS.Vector a) where toParamSchema _ = toParamSchema (Proxy :: Proxy [a])
instance ToParamSchema a => ToParamSchema (VU.Vector a) where toParamSchema _ = toParamSchema (Proxy :: Proxy [a])

instance ToParamSchema a => ToParamSchema (Set a) where
  toParamSchema _ = toParamSchema (Proxy :: Proxy [a])
    & uniqueItems ?~ True

instance ToParamSchema a => ToParamSchema (HashSet a) where
  toParamSchema _ = toParamSchema (Proxy :: Proxy (Set a))

-- |
-- >>> BSL.putStrLn $ encodePretty $ toParamSchema (Proxy :: Proxy ())
-- {
--     "enum": [
--         "_"
--     ],
--     "type": "string"
-- }
instance ToParamSchema () where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiString
    & enum_ ?~ ["_"]

instance ToParamSchema UUID where
  toParamSchema _ = mempty
    & type_ ?~ OpenApiString
    & format ?~ "uuid"

-- | A configurable generic @'Schema'@ creator.
--
-- >>> :set -XDeriveGeneric
-- >>> data Color = Red | Blue deriving Generic
-- >>> BSL.putStrLn $ encodePretty $ genericToParamSchema defaultSchemaOptions (Proxy :: Proxy Color)
-- {
--     "enum": [
--         "Blue",
--         "Red"
--     ],
--     "type": "string"
-- }
genericToParamSchema :: forall a t. (Generic a, GToParamSchema (Rep a)) => SchemaOptions -> Proxy a -> Schema
genericToParamSchema opts _ = gtoParamSchema opts (Proxy :: Proxy (Rep a)) mempty

class GToParamSchema (f :: * -> *) where
  gtoParamSchema :: SchemaOptions -> Proxy f -> Schema -> Schema

instance GToParamSchema f => GToParamSchema (D1 d f) where
  gtoParamSchema opts _ = gtoParamSchema opts (Proxy :: Proxy f)

instance Constructor c => GToParamSchema (C1 c U1) where
  gtoParamSchema = genumParamSchema

instance GToParamSchema f => GToParamSchema (C1 c (S1 s f)) where
  gtoParamSchema opts _ = gtoParamSchema opts (Proxy :: Proxy f)

instance ToParamSchema c => GToParamSchema (K1 i c) where
  gtoParamSchema _ _ _ = toParamSchema (Proxy :: Proxy c)

instance (GEnumParamSchema f, GEnumParamSchema g) => GToParamSchema (f :+: g) where
  gtoParamSchema opts _ = genumParamSchema opts (Proxy :: Proxy (f :+: g))

class GEnumParamSchema (f :: * -> *) where
  genumParamSchema :: SchemaOptions -> Proxy f -> Schema -> Schema

instance (GEnumParamSchema f, GEnumParamSchema g) => GEnumParamSchema (f :+: g) where
  genumParamSchema opts _ = genumParamSchema opts (Proxy :: Proxy f) . genumParamSchema opts (Proxy :: Proxy g)

instance Constructor c => GEnumParamSchema (C1 c U1) where
  genumParamSchema opts _ s = s
    & type_ ?~ OpenApiString
    & enum_ %~ addEnumValue tag
    where
      tag = toJSON (constructorTagModifier opts (conName (Proxy3 :: Proxy3 c f p)))

      addEnumValue x Nothing    = Just [x]
      addEnumValue x (Just xs)  = Just (x:xs)

data Proxy3 a b c = Proxy3

-- $setup
-- >>> import Data.Aeson (encode)
-- >>> import Data.OpenApi.Internal.Utils
