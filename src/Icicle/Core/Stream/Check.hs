{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Core.Stream.Check (
      checkStream
    , StreamEnv (..)
    , streamEnv
    ) where

import              Icicle.Common.Type
import              Icicle.Core.Exp

import              Icicle.Core.Stream.Stream
import              Icicle.Core.Stream.Error

import              P

import qualified    Data.Map as Map
import              Data.Either.Combinators


data StreamEnv n =
 StreamEnv
 { scalars  :: Env n Type
 , streams  :: Env n ValType
 , concrete :: ValType
 }

streamEnv :: Env n Type -> ValType -> StreamEnv n
streamEnv pre conc
 = StreamEnv pre Map.empty conc


checkStream
        :: Ord n
        => StreamEnv n -> Stream n
        -> Either (StreamError n) ValType
checkStream se s
 = case s of
    Source
     -> return $ PairT (concrete se) DateTimeT
    SourceWindowedDays _
     -> return $ PairT (concrete se) DateTimeT
    STrans st f n
     -> do  inp <- lookupOrDie StreamErrorVarNotInEnv (streams se) n
            fty <- mapLeft     StreamErrorExp $ checkExp coreFragment (scalars se) f

            requireSame (StreamErrorTypeError f)
                        (funOfVal $ inputOfStreamTransform st) (funOfVal inp)
            requireSame (StreamErrorTypeError f)
                        (typeOfStreamTransform st)              fty

            return (outputOfStreamTransform st)

