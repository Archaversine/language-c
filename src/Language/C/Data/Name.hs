{-# LANGUAGE DeriveDataTypeable #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Language.C.Data.Name
-- Copyright   :  (c) 2008 Benedikt Huber
-- License     :  BSD-style
-- Maintainer  :  benedikt.huber@gmail.com
-- Stability   :  experimental
-- Portability :  ghc
--
-- Unique Names with fast equality (newtype 'Int')
module Language.C.Data.Name (
Name(..),newNameSupply, namesStartingFrom
) where
import Data.Data (Data)
import Data.Ix
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)

-- | Name is a unique identifier
newtype Name = Name { nameId :: Int }
  deriving (Show, Read, Eq, Ord, Ix, Data, Generic)

instance NFData Name

instance Enum Name where
    toEnum = Name
    fromEnum (Name n) = n

-- | return an infinite stream of 'Name's starting with @nameId@ 0
newNameSupply :: [Name]
newNameSupply = namesStartingFrom 0

-- | get the infinite stream of unique names starting from the given integer
namesStartingFrom :: Int -> [Name]
namesStartingFrom k = [Name k..]
