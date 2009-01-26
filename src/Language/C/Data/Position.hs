{-# LANGUAGE DeriveDataTypeable, PatternGuards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Language.C.Data.Position
-- Copyright   :  (c) [1995..2000] Manuel M. T. Chakravarty
--                    [2008..2009] Benedikt Huber
-- License     :  BSD-style
-- Maintainer  :  benedikt.huber@gmail.com
-- Stability   :  experimental
-- Portability :  ghc
--
-- Source code position
-----------------------------------------------------------------------------
module Language.C.Data.Position (
  --
  -- source text positions
  --
  Position(),
  position,
  PosLength,
  posFile,posRow,posColumn,posOffset,
  initPos, isSourcePos,
  nopos, isNoPos,
  builtinPos, isBuiltinPos,
  internalPos, isInternalPos,
  incPos, retPos,
  Pos(..),
) where
import Data.Generics

-- | uniform representation of source file positions
data Position = Position { posOffset :: {-# UNPACK #-} !Int
                         , posFile :: String
                         , posRow :: {-# UNPACK #-} !Int
                         , posColumn :: {-# UNPACK #-} !Int
                         }
              | NoPosition
              | BuiltinPosition
              | InternalPosition
                deriving (Eq, Ord, Typeable, Data)

type PosLength = (Position,Int)

instance Show Position where
  show (Position _ fname row _) = "(" ++ show fname ++ ": line " ++ show row ++ ")"
  show NoPosition               = "<no file>"
  show BuiltinPosition          = "<builtin>"
  show InternalPosition         = "<internal>"

{-# DEPRECATED posColumn "column number information is inaccurate in presence of macros - do not rely on it." #-}

-- | get the column of the specified position.
-- Has been removed, as column information is inaccurate before preprocessing,
-- and meaningless afterwards (because of #LINE pragmas).
posColumn :: Position -> Int
posColumn (Position _ _ _ col) = col

-- | get the absolute offset of the position (in the preprocessed source)
posOffset :: Position -> Int
posOffset (Position off _ _ col) = off

-- | class of type which aggregate a source code location
class Pos a where
    posOf :: a -> Position

-- | initialize a Position to the start of the translation unit starting in the given file
initPos :: FilePath -> Position
initPos file = Position 0 file 1 1

-- | returns @True@ if the given position refers to an actual source file
isSourcePos :: Position -> Bool
isSourcePos (Position _ _ _ _) = True
isSourcePos _                  = False

-- | no position (for unknown position information)
nopos :: Position
nopos  = NoPosition

-- | returns @True@ if the there is no position information available
isNoPos :: Position -> Bool
isNoPos NoPosition = True
isNoPos _          = False

-- | position attached to built-in objects
--
builtinPos :: Position
builtinPos  = BuiltinPosition

-- | returns @True@ if the given position refers to a builtin definition
isBuiltinPos :: Position -> Bool
isBuiltinPos BuiltinPosition = True
isBuiltinPos _               = False

-- | position used for internal errors
internalPos :: Position
internalPos = InternalPosition

-- | returns @True@ if the given position is internal
isInternalPos :: Position -> Bool
isInternalPos InternalPosition = True
isInternalPos _                = False

{-# INLINE incPos #-}
-- | advance column
incPos :: Position -> Int -> Position
incPos (Position offs fname row col) n = Position (offs + n) fname row (col + n)
incPos p _                             = p

{-# INLINE retPos #-}
-- | advance to next line
retPos :: Position -> Position
retPos (Position offs fname row _) = Position (offs+1) fname (row + 1) 1
retPos p                           = p
