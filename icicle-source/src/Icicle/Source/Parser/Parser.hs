{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Icicle.Source.Parser.Parser (
    top
  , query
  , context
  , exp
  , windowUnit
  , functions
  , function
  ) where

import qualified        Icicle.Source.Lexer.Token  as T
import                  Icicle.Source.Parser.Token
import                  Icicle.Source.Parser.Operators
import                  Icicle.Source.Parser.Constructor
import qualified        Icicle.Source.Query        as Q

import                  Icicle.Common.Base         as B
import                  Icicle.Data.Name

import                  P hiding (exp)

import                  Text.Parsec (many1, parserFail, getPosition, (<?>), sepEndBy, try, notFollowedBy)

top :: OutputId -> Parser (Q.QueryTop T.SourcePos Var)
top name
 = do   pKeyword T.Feature                                      <?> "feature start"
        v <- pUnresolvedInputId                                 <?> "input source"
        pFlowsInto
        q <- query                                              <?> "query"
        return $ Q.QueryTop v name q

functions :: Parser [((T.SourcePos, Name Var), (Q.Exp T.SourcePos Var))]
functions
 = ((,) <$> ((,) <$> getPosition <*> pVariable) <*> function) `sepEndBy` (pEq T.TStatementEnd)

function :: Parser (Q.Exp T.SourcePos Var)
function
 = do   vs <- many ((,) <$> getPosition <*> pVariable)      <?> "function variables"
        pEq T.TEqual                                        <?> "equals"
        q <- (,) <$> getPosition <*> query
        let lams = foldr (uncurry Q.Lam) (uncurry simpNested q) vs
        return lams
 where
  simpNested _ (Q.Query [] x)
   = x
  simpNested p q
   = Q.Nested p q


query :: Parser (Q.Query T.SourcePos Var)
query
 = do   cs <- many context                                  <?> "contexts"
        x  <- exp                                           <?> "expression"
        return $ Q.Query cs x


context :: Parser (Q.Context T.SourcePos Var)
context
 = do   c <- context1                                       <?> "context"
        pFlowsInto
        return c
 where
  context1
   =   pKeyword T.Windowed *> cwindowed
   <|> pKeyword T.Group    *> (cgroupfold <|> (flip Q.GroupBy <$> exp <*> getPosition))
   <|> pKeyword T.Distinct *> (flip Q.Distinct <$> exp      <*> getPosition)
   <|> pKeyword T.Filter   *> (flip Q.Filter   <$> exp      <*> getPosition)
   <|> pKeyword T.Latest   *> (flip Q.Latest   <$> pLitInt  <*> getPosition)
   <|> pKeyword T.Let      *> (try clet        <|> cpatternbinding)
   <|> cletfold

  cwindowed
   = cwindowed2 <|> cwindowed1

  cwindowed1
   = do t1 <- windowUnit
        p  <- getPosition
        return $ Q.Windowed p t1 Nothing

  cwindowed2
   = do pKeyword T.Between
        p <- getPosition
        t1 <- windowUnit
        pKeyword T.And
        t2 <- windowUnit
        return $ Q.Windowed p t2 $ Just t1

  cgroupfold
   = do pKeyword T.Fold
        p <- getPosition
        (k, v) <- keyval
        pEq T.TEqual
        e <- exp
        return $ Q.GroupFold p k v e

  clet
   = do n <- pVariable                                      <?> "function binding name"
        p <- getPosition
        x <- function                                       <?> "let definition expression"
        return $ Q.Let p (Q.PatVariable n) x

  cpatternbinding
   = do n <- pattern                                        <?> "binding pattern"
        p <- getPosition
        pEq T.TEqual
        x <- exp                                            <?> "let definition expression"
        return $ Q.Let p n x

  cletfold
   = do ft <- foldtype                                      <?> "let fold"
        p <- getPosition
        n <- pattern
        pEq T.TEqual
        z <- exp                                            <?> "initial value"
        pEq T.TFollowedBy                                   <?> "colon (:)"
        k <- exp                                            <?> "fold expression"
        return $ Q.LetFold p (Q.Fold n z k ft)


  keyval
    = do p <- pattern
         case p of
           Q.PatCon Q.ConTuple [k, v]
             -> return (k, v)
           _ -> mzero

  foldtype
    =   pKeyword T.Fold1 *> return Q.FoldTypeFoldl1
    <|> pKeyword T.Fold  *> return Q.FoldTypeFoldl

pattern :: Parser (Q.Pattern Var)
pattern
 = do e <- exp
      checkPat e                                            <?> "pattern"

exp :: Parser (Q.Exp T.SourcePos Var)
exp
 = do   xs <- many1 ((Left <$> exp1) <|> op)                <?> "expression"
        either (parserFail.renderDefixError) return
               (defix xs)
 where
  -- Get the position before reading the operator
  op = do o <- pOperator
          p <- getPosition
          return (Right (o,p))

exp1 :: Parser (Q.Exp T.SourcePos Var)
exp1
 =   (flip Q.Var      <$> var        <*> getPosition)
 <|> (flip Q.Prim     <$> primitives <*> getPosition)
 <|> (flip simpNested <$> parens     <*> getPosition)
 <|> parseCase
 <?> "expression"
 where
  var
   = try pProjections <|> pVariable

  simpNested _ (Q.Query [] x)
   = x
  simpNested p q
   = Q.Nested p q

  parens
   = pParenL *> query <* pParenR  <?> "sub-expression or nested query"

  parseCase
   = do pEq $ T.TKeyword T.Case
        pos <- getPosition
        scrut <- exp
        alts  <- many1 parseAlt
        pEq $ T.TKeyword T.End
        return $ Q.Case pos scrut alts

  parseAlt
   = do pEq $ T.TAlternative
        pat <- pattern
        pEq $ T.TFunctionArrow
        xx  <- exp
        return (pat, xx)

--------------------------------------------------------------------------------

windowUnit :: Parser B.WindowUnit
windowUnit
 = do i <- pLitInt <?> "window amount"
      unit T.Days (B.Days i) <|> unit T.Months (B.Months i) <|> unit T.Weeks (B.Weeks i)
 where
  unit kw q
   = pKeyword kw *> return q

primitives :: Parser Q.Prim
primitives
 =   timePrimitives
 <|> ((Q.Lit . Q.LitInt)    <$> pLitInt)
 <|> ((Q.Lit . Q.LitDouble) <$> pLitDouble)
 <|> ((Q.Lit . Q.LitString) <$> pLitString)
 <|> ((Q.Lit . Q.LitTime)   <$> pLitTime)
 <|> (Q.PrimCon             <$> constructor)
 <?> "primitive"

timePrimitives :: Parser Q.Prim
timePrimitives
 =   try  (Q.Fun (Q.BuiltinTime Q.DaysBetween)
            <$ pKeyword T.Days
            <* pKeyword T.Between)
 <|> try  (Q.Fun (Q.BuiltinTime Q.DaysJulianEpoch)
             <$ pKeyword T.Days
             <* notFollowedBy (pKeyword T.Before <|> pKeyword T.After))
 <|> try  (Q.Fun (Q.BuiltinTime Q.SecondsBetween)
            <$ pKeyword T.Seconds
            <* pKeyword T.Between)
 <|> try  (Q.Fun (Q.BuiltinTime Q.SecondsJulianEpoch)
             <$ pKeyword T.Seconds
             <* notFollowedBy (pKeyword T.Before <|> pKeyword T.After))
