{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Dictionary (
    Dictionary (..)
  , Definition (..)
  , Virtual (..)
  , demographics
  ) where

import           Icicle.Data

import qualified Icicle.Core.Base            as N -- N for name
import qualified Icicle.Core.Type            as T
import qualified Icicle.Core.Exp             as X
import           Icicle.Core.Exp.Combinators
import qualified Icicle.Core.Exp.Prim        as P
import qualified Icicle.Core.Stream          as S
import qualified Icicle.Core.Reduce          as R
import qualified Icicle.Core.Program.Program as P

import           P

import           Data.Text


data Dictionary =
  Dictionary [(Attribute, Definition)]
  deriving (Eq, Show)


data Definition =
    ConcreteDefinition Encoding
  | VirtualDefinition  Virtual
  deriving (Eq, Show)


data Virtual =
  Virtual {
      -- | Name of concrete attribute used as input
      concrete :: Attribute
    , program  :: P.Program Text
    } deriving (Eq, Show)



-- | Example demographics dictionary
-- Hard-coded for now
demographics :: Dictionary
demographics =
 Dictionary 
 [ (Attribute "gender",             ConcreteDefinition StringEncoding)
 , (Attribute "age",                ConcreteDefinition IntEncoding)
 , (Attribute "state_of_residence", ConcreteDefinition StringEncoding)
 , (Attribute "salary",             ConcreteDefinition IntEncoding)
 
  -- Useless virtual features
 , (Attribute "sum of all salary",      
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") program_sum)

 , (Attribute "count all salary entries",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") program_count)

 , (Attribute "mean of all salary",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") program_mean)

 , (Attribute "filter >= 70k; sum",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") program_filt_sum)

 , (Attribute "Latest 2 salary entries, unwindowed",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") (program_latest 2))

 , (Attribute "Sum of last 3000 days",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") (program_windowed_sum 3000))

 , (Attribute "Count unique",
                                    VirtualDefinition
                                  $ Virtual (Attribute "salary") program_count_unique)
 ]


-- | Dead simple sum
program_sum :: P.Program Text
program_sum
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.Source)]
 , P.reduces    = [(N.Name "red", fold_sum (N.Name "inp"))]
 , P.postcomps  = []
 , P.returns    = var "red"
 }

fold_sum :: N.Name Text -> R.Reduce Text
fold_sum inp
 = R.RFold t t
        (lam t $ \a -> lam t $ \b -> a +~ b)
        (constI 0)
        inp
 where
  t = T.IntT


-- | Count
program_count :: P.Program Text
program_count
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.Source)
                  ,(N.Name "ones", S.STrans (S.SMap T.IntT T.IntT) const1 (N.Name "inp"))]
 , P.reduces    = [(N.Name "count", fold_sum (N.Name "ones"))]
 , P.postcomps  = []
 , P.returns    = X.XVar (N.Name "count")
 }
 where
  const1 = lam T.IntT $ \_ -> constI 1


-- | Mean salary
program_mean :: P.Program Text
program_mean
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.Source)
                  ,(N.Name "ones", S.STrans (S.SMap T.IntT T.IntT) const1 (N.Name "inp"))]
 , P.reduces    = [(N.Name "count", fold_sum (N.Name "ones"))
                  ,(N.Name "sum",   fold_sum (N.Name "inp"))]
 , P.postcomps  = []
 , P.returns    = var "sum" /~ var "count"
 }
 where
  const1 = lam T.IntT $ \_ -> constI 1


-- | Filtered sum
program_filt_sum :: P.Program Text
program_filt_sum
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.Source)
                  ,(N.Name "filts", S.STrans (S.SFilter T.IntT) gt (N.Name "inp"))]
 , P.reduces    = [(N.Name "sum",   fold_sum (N.Name "filts"))]
 , P.postcomps  = []
 , P.returns    = X.XVar (N.Name "sum")
 }
 where
  -- e > 70000
  gt = lam T.IntT $ \e -> e >~ constI 70000


-- | Latest N
program_latest :: Int -> P.Program Text
program_latest n
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.Source)]
 , P.reduces    = [(N.Name "latest", R.RLatest T.IntT (constI n) (N.Name "inp"))]
 , P.postcomps  = []
 , P.returns    = X.XVar (N.Name "latest")
 }

-- | Sum of last n days
program_windowed_sum :: Int -> P.Program Text
program_windowed_sum days
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp", S.SourceWindowedDays days)]
 , P.reduces    = [(N.Name "sum",   fold_sum (N.Name "inp"))]
 , P.postcomps  = []
 , P.returns    = X.XVar (N.Name "sum")
 }

program_count_unique :: P.Program Text
program_count_unique
 = P.Program
 { P.input      = T.IntT
 , P.precomps   = []
 , P.streams    = [(N.Name "inp",  S.Source)]
 , P.reduces    = [(N.Name "uniq",
                        R.RFold T.IntT mT
                        (lam mT $ \acc -> lam T.IntT $ \v -> X.XPrim (P.PrimMap $ P.PrimMapInsertOrUpdate T.IntT T.IntT) @~ (lam T.IntT $ \_ -> constI 1) @~ constI 1 @~ v @~ acc)
                        (X.XPrim (P.PrimConst $ P.PrimConstMapEmpty T.IntT T.IntT))
                        (N.Name "inp"))]
 , P.postcomps  = [(N.Name "size", X.XPrim (P.PrimFold (P.PrimFoldMap T.IntT T.IntT) T.IntT) @~ (lam T.IntT $ \a -> lam T.IntT $ \_ -> lam T.IntT $ \b -> a +~ b) @~ constI 0 @~ var "uniq")]
 , P.returns    = var "size"
 }
 where
  mT = T.MapT T.IntT T.IntT