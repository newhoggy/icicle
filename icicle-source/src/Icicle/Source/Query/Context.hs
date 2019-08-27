-- | Contexts that filter, group, and do stuff on the input
-- before they hit the expression.
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Icicle.Source.Query.Context (
    Context'  (..)
  , Fold      (..)
  , FoldType  (..)
  , annotOfContext
  ) where

import           GHC.Generics (Generic)

import           Icicle.Source.Query.Constructor
import           Icicle.Source.Query.Exp
import           Icicle.Internal.Pretty
import           Icicle.Common.Base

import           P


data Context' q a n
 = Windowed a WindowUnit (Maybe WindowUnit)
 | Latest a Int
 | GroupBy   a             (Exp' q a n)
 | Distinct  a             (Exp' q a n)
 | Filter    a             (Exp' q a n)
 | LetFold   a             (Fold q a n)
 | Let       a (Pattern n) (Exp' q a n)
 | GroupFold a (Pattern n) (Pattern n) (Exp' q a n)
 deriving (Show, Eq, Ord, Generic)

instance (NFData (q a n), NFData a, NFData n) => NFData (Context' q a n)

instance TraverseAnnot q => TraverseAnnot (Context' q)  where
  traverseAnnot f cc =
    case cc of
      Windowed  a b c   -> Windowed  <$> f a <*> pure b <*> pure c
      Latest    a i     -> Latest    <$> f a <*> pure i
      GroupBy   a x     -> GroupBy   <$> f a <*> traverseAnnot f x
      GroupFold a k v x -> GroupFold <$> f a <*> pure k <*> pure v <*> traverseAnnot f x
      Distinct  a x     -> Distinct  <$> f a <*> traverseAnnot f x
      Filter    a x     -> Filter    <$> f a <*> traverseAnnot f x
      LetFold   a ff    -> LetFold   <$> f a <*> traverseAnnot f ff
      Let      a n x    -> Let       <$> f a <*> pure n <*> traverseAnnot f x

data Fold q a n
 = Fold
 { foldBind :: Pattern n
 , foldInit :: Exp' q a n
 , foldWork :: Exp' q a n
 , foldType :: FoldType }
 deriving (Show, Eq, Ord, Generic)

instance TraverseAnnot q => TraverseAnnot (Fold q)  where
  traverseAnnot f ff =
    Fold (foldBind ff)
      <$> traverseAnnot f (foldInit ff)
      <*> traverseAnnot f (foldWork ff)
      <*> pure            (foldType ff)

instance (NFData (q a n), NFData a, NFData n) => NFData (Fold q a n)

data FoldType
 = FoldTypeFoldl1
 | FoldTypeFoldl
 deriving (Show, Eq, Ord, Generic)

instance NFData FoldType

annotOfContext :: Context' q a n -> a
annotOfContext c
 = case c of
    Windowed  a _ _   -> a
    Latest    a _     -> a
    GroupBy   a _     -> a
    GroupFold a _ _ _ -> a
    Distinct  a _     -> a
    Filter    a _     -> a
    LetFold   a _     -> a
    Let       a _ _   -> a

instance (Pretty n, Pretty (q a n)) => Pretty (Context' q a n) where
  pretty = \case
    Windowed _ newer Nothing ->
      prettyKeyword "windowed" <+> pretty newer

    Windowed _ newer (Just older) ->
      prettyKeyword "windowed between" <+>
      pretty older <+>
      prettyKeyword "and" <+>
      pretty newer

    Latest _ i ->
      prettyKeyword "latest" <+> annotate AnnConstant (pretty i)

    GroupBy _ x ->
      prettyKeyword "group" <+> align (pretty x)

    GroupFold _ n1 n2 x ->
      vsep [
          prettyKeyword "group fold" <+> pretty (n1, n2) <+> prettyPunctuation "="
        , indent 2 . align $
            pretty x
        ]

    Distinct _ x ->
      prettyKeyword "distinct" <+> align (pretty x)

    Filter _ x ->
      prettyKeyword "filter" <+> align (pretty x)

    LetFold _ f ->
      vsep [
          pretty (foldType f) <+> annotate AnnBinding (pretty (foldBind f)) <+> prettyPunctuation "="
        , indent 2 . align $
            pretty (foldInit f) <+> prettyPunctuation ":" <+> pretty (foldWork f)
        ]

    Let _ b x ->
      vsep [
          prettyKeyword "let" <+> annotate AnnBinding (pretty b) <+> prettyPunctuation "="
        , indent 2 . align $
            pretty x
        ]

instance Pretty FoldType where
  pretty = \case
    FoldTypeFoldl1 ->
      prettyKeyword "fold1"
    FoldTypeFoldl ->
      prettyKeyword "fold"
