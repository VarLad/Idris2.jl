module Compiler.Julia

import Compiler.Common
import Compiler.ES.TailRec
import Compiler.Julia.Runtime

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.Directory
import Core.FC
import Core.Name
import Core.Name.Namespace
import Core.Options
import Core.TT
import Core.TT.Primitive

import Data.List
import Data.Maybe
import Data.String
import Data.Vect

import Idris.Syntax

import Libraries.Utils.Path

import Protocol.Hex

import System

%default covering

--------------------------------------------------------------------------------
--          Names
--------------------------------------------------------------------------------

juliaReserved : List String
juliaReserved =
  [ "abstract", "baremodule", "begin", "break", "catch", "const", "continue"
  , "do", "else", "elseif", "end", "export", "false", "finally", "for"
  , "function", "global", "if", "import", "in", "isa", "let", "local"
  , "macro", "module", "mutable", "outer", "primitive", "quote", "return"
  , "struct", "true", "try", "using", "where", "while"
  , "nothing", "missing", "Any", "Type", "Symbol", "String", "Char", "Int"
  , "Integer", "Float64", "Bool", "UInt8", "UInt16", "UInt32", "UInt64"
  , "Int8", "Int16", "Int32", "Int64", "Vector", "Tuple", "BigInt"
  , "print", "println", "show", "repr", "string", "parse", "read"
  , "readline", "write", "open", "close", "join", "split", "strip"
  , "replace", "length", "size", "first", "last", "chop", "reverse"
  , "sort", "map", "filter", "reduce", "foldl", "foldr", "sum", "prod"
  , "min", "max", "abs", "sign", "floor", "ceil", "round", "trunc"
  , "div", "fld", "cld", "rem", "mod", "xor", "and", "or", "not"
  , "cmp", "isequal", "isless", "identity", "collect", "enumerate"
  , "zip", "iterate", "push!", "pop!", "append!", "prepend!", "insert!"
  , "delete!", "empty!", "isempty", "unique", "union", "intersect"
  , "setdiff", "eval", "include", "require", "getindex", "setindex!"
  , "getproperty", "setproperty!", "getglobal", "setglobal!", "isdefined"
  , "isassigned", "typeof", "convert", "promote", "throw", "error"
  , "reinterpret", "bitcast", "hash", "Exception", "SubString", "IOBuffer"
  , "Ref", "Array", "NamedTuple", "Dict", "Set", "Base", "Core", "Main"
  , "Sys", "Float32", "Float16", "UInt128", "Int128"
  ]

jlIdent : String -> String
jlIdent s = concatMap okchar (unpack s)
  where
    okchar : Char -> String
    okchar '_' = "_"
    okchar c = if isAlphaNum c
                  then singleton c
                  else "x" ++ asHex (cast (ord c))

jlSafe : String -> String
jlSafe s =
  let m = jlIdent s in
  case strM m of
       StrCons c _ => if isDigit c then "_" ++ m else m
       StrNil => "x"

jlKeywordSafe : String -> String
jlKeywordSafe s = if s `elem` juliaReserved then s ++ "_" else s

jlUserName : UserName -> String
jlUserName (Basic n) = jlKeywordSafe (jlSafe n)
jlUserName (Field n) = "rf__" ++ jlSafe n
jlUserName Underscore = "u__"

jlName : Name -> String
jlName (NS ns n) = jlSafe (showNSWithSep "_" ns) ++ "_" ++ jlName n
jlName (UN n) = jlUserName n
jlName (MN n i) = jlSafe n ++ "_" ++ show i
jlName (PV n d) = "pat__" ++ jlName n
jlName (DN _ n) = jlName n
jlName (Nested (i, x) n) = "n__" ++ show i ++ "_" ++ show x ++ "_" ++ jlName n
jlName (CaseBlock x y) = "case__" ++ jlSafe x ++ "_" ++ show y
jlName (WithBlock x y) = "with__" ++ jlSafe x ++ "_" ++ show y
jlName (Resolved i) = "fn__" ++ show i

||| Name used when a compiled expression refers to a top level function.
||| The tail call loop is provided by the runtime, so refer to it directly.
jlRefName : Name -> String
jlRefName (UN (Basic "__tailRec")) = "_idris_tailRec"
jlRefName n = jlName n

--------------------------------------------------------------------------------
--          Strings and constants
--------------------------------------------------------------------------------

jlString : String -> String
jlString s = "\"" ++ concatMap esc (unpack s) ++ "\""
  where
    padHex : String -> String
    padHex h = pack (replicate (minus 4 (length h)) '0') ++ h

    esc : Char -> String
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c =
      if ord c < 32 || ord c > 126
         then "\\u" ++ padHex (asHex (cast (ord c)))
         else singleton c

jlConstant : Constant -> String
jlConstant (I x)   = "Int64(" ++ show x ++ ")"
jlConstant (I8 x)  = "Int8(" ++ show x ++ ")"
jlConstant (I16 x) = "Int16(" ++ show x ++ ")"
jlConstant (I32 x) = "Int32(" ++ show x ++ ")"
jlConstant (I64 x) = "Int64(" ++ show x ++ ")"
jlConstant (BI x)  =
  if x >= -9223372036854775808 && x <= 9223372036854775807
     then "Int64(" ++ show x ++ ")"
     else "BigInt(" ++ show x ++ ")"
jlConstant (B8 x)  = "UInt8(" ++ show x ++ ")"
jlConstant (B16 x) = "UInt16(" ++ show x ++ ")"
jlConstant (B32 x) = "UInt32(" ++ show x ++ ")"
jlConstant (B64 x) = "UInt64(" ++ show x ++ ")"
jlConstant (Str s) = jlString s
jlConstant (Ch c)  = "Char(" ++ show (ord c) ++ ")"
jlConstant (Db x)  = show x
jlConstant (PrT t) = "Symbol(" ++ jlString (show t) ++ ")"
jlConstant WorldVal = "nothing"

jlTag : Name -> Maybe Int -> String
jlTag _ (Just t) = show t
jlTag n Nothing = "Symbol(" ++ jlString (show n) ++ ")"

||| Build a Julia tuple literal. A one element tuple keeps its trailing comma.
jlTuple : List String -> String
jlTuple xs =
  let inner = showSep ", " xs in
  "(" ++ inner ++ (if length xs == 1 then "," else "") ++ ")"

--------------------------------------------------------------------------------
--          Primitive operations
--------------------------------------------------------------------------------

jlIntType : IntKind -> String
jlIntType (Signed Unlimited) = "BigInt"
jlIntType (Signed (P 8)) = "Int8"
jlIntType (Signed (P 16)) = "Int16"
jlIntType (Signed (P 32)) = "Int32"
jlIntType (Signed (P 64)) = "Int64"
jlIntType (Unsigned 8) = "UInt8"
jlIntType (Unsigned 16) = "UInt16"
jlIntType (Unsigned 32) = "UInt32"
jlIntType (Unsigned 64) = "UInt64"
jlIntType _ = "Int64"

jlWrapName : IntKind -> String
jlWrapName (Signed (P 8)) = "_idris_wrap_int8"
jlWrapName (Signed (P 16)) = "_idris_wrap_int16"
jlWrapName (Signed (P 32)) = "_idris_wrap_int32"
jlWrapName (Signed (P 64)) = "_idris_wrap_int64"
jlWrapName (Unsigned 8) = "_idris_wrap_uint8"
jlWrapName (Unsigned 16) = "_idris_wrap_uint16"
jlWrapName (Unsigned 32) = "_idris_wrap_uint32"
jlWrapName (Unsigned 64) = "_idris_wrap_uint64"
jlWrapName _ = "BigInt"

jlIntToInt : IntKind -> String -> String
jlIntToInt (Signed Unlimited) x = "_idris_integer(BigInt(" ++ x ++ "))"
jlIntToInt k x = jlWrapName k ++ "(" ++ x ++ ")"

jlCast : PrimType -> PrimType -> String -> String
jlCast from to x =
  if from == to then x
  else case (from, to) of
    (CharType, StringType) => "string(" ++ x ++ ")"
    (StringType, CharType) => "_idris_int_to_char(_idris_parse_bigint(" ++ x ++ "))"
    (CharType, DoubleType) => "Float64(Int(" ++ x ++ "))"
    (DoubleType, CharType) => "_idris_int_to_char(trunc(BigInt, " ++ x ++ "))"
    (StringType, DoubleType) => "_idris_parse_double(" ++ x ++ ")"
    (DoubleType, StringType) => "string(" ++ x ++ ")"
    (CharType, _) => intTo ("Int(" ++ x ++ ")") to
    (StringType, _) => intTo ("_idris_parse_bigint(" ++ x ++ ")") to
    (DoubleType, _) => intFromDouble x to
    (_, CharType) => "_idris_int_to_char(" ++ x ++ ")"
    (_, StringType) => "string(" ++ x ++ ")"
    (_, DoubleType) => "Float64(" ++ x ++ ")"
    (_, _) => case intKind to of
        Just k => jlIntToInt k x
        Nothing => x
  where
    intTo : String -> PrimType -> String
    intTo e t = case intKind t of
        Just k => jlIntToInt k e
        Nothing => x

    intFromDouble : String -> PrimType -> String
    intFromDouble e t = case intKind t of
        Just (Signed Unlimited) => "_idris_integer(trunc(BigInt, " ++ e ++ "))"
        Just k => jlWrapName k ++ "(trunc(BigInt, " ++ e ++ "))"
        Nothing => x

jlOp : {arity : Nat} -> PrimFn arity -> Vect arity String -> String
jlOp (Add IntegerType) [x, y] = "_idris_iadd(" ++ x ++ ", " ++ y ++ ")"
jlOp (Add _) [x, y] = "(" ++ x ++ " + " ++ y ++ ")"
jlOp (Sub IntegerType) [x, y] = "_idris_isub(" ++ x ++ ", " ++ y ++ ")"
jlOp (Sub _) [x, y] = "(" ++ x ++ " - " ++ y ++ ")"
jlOp (Mul IntegerType) [x, y] = "_idris_imul(" ++ x ++ ", " ++ y ++ ")"
jlOp (Mul _) [x, y] = "(" ++ x ++ " * " ++ y ++ ")"
jlOp (Div DoubleType) [x, y] = "(" ++ x ++ " / " ++ y ++ ")"
jlOp (Div IntegerType) [x, y] = "_idris_idiv(" ++ x ++ ", " ++ y ++ ")"
jlOp (Div _) [x, y] = "_idris_div(" ++ x ++ ", " ++ y ++ ")"
jlOp (Mod IntegerType) [x, y] = "_idris_imod(" ++ x ++ ", " ++ y ++ ")"
jlOp (Mod _) [x, y] = "_idris_mod(" ++ x ++ ", " ++ y ++ ")"
jlOp (Neg IntegerType) [x] = "_idris_ineg(" ++ x ++ ")"
jlOp (Neg _) [x] = "(-" ++ x ++ ")"
jlOp (ShiftL IntegerType) [x, y] = "_idris_ishl(" ++ x ++ ", " ++ y ++ ")"
jlOp (ShiftL _) [x, y] = "(" ++ x ++ " << " ++ y ++ ")"
jlOp (ShiftR IntegerType) [x, y] = "_idris_ishr(" ++ x ++ ", " ++ y ++ ")"
jlOp (ShiftR _) [x, y] = "(" ++ x ++ " >> " ++ y ++ ")"
jlOp (BAnd IntegerType) [x, y] = "_idris_iand(" ++ x ++ ", " ++ y ++ ")"
jlOp (BAnd _) [x, y] = "(" ++ x ++ " & " ++ y ++ ")"
jlOp (BOr IntegerType) [x, y] = "_idris_ior(" ++ x ++ ", " ++ y ++ ")"
jlOp (BOr _) [x, y] = "(" ++ x ++ " | " ++ y ++ ")"
jlOp (BXOr IntegerType) [x, y] = "_idris_ixor(" ++ x ++ ", " ++ y ++ ")"
jlOp (BXOr _) [x, y] = "xor(" ++ x ++ ", " ++ y ++ ")"
jlOp (LT _) [x, y] = "(" ++ x ++ " < " ++ y ++ " ? 1 : 0)"
jlOp (LTE _) [x, y] = "(" ++ x ++ " <= " ++ y ++ " ? 1 : 0)"
jlOp (EQ _) [x, y] = "(" ++ x ++ " == " ++ y ++ " ? 1 : 0)"
jlOp (GTE _) [x, y] = "(" ++ x ++ " >= " ++ y ++ " ? 1 : 0)"
jlOp (GT _) [x, y] = "(" ++ x ++ " > " ++ y ++ " ? 1 : 0)"
jlOp StrLength [x] = "length(" ++ x ++ ")"
jlOp StrHead [x] = "_idris_strHead(" ++ x ++ ")"
jlOp StrTail [x] = "_idris_strTail(" ++ x ++ ")"
jlOp StrIndex [x, y] = "_idris_strIndex(" ++ x ++ ", " ++ y ++ ")"
jlOp StrCons [x, y] = "_idris_strCons(" ++ x ++ ", " ++ y ++ ")"
jlOp StrAppend [x, y] = "(" ++ x ++ " * " ++ y ++ ")"
jlOp StrReverse [x] = "_idris_strReverse(" ++ x ++ ")"
jlOp StrSubstr [x, y, z] = "_idris_strSubstr(" ++ x ++ ", " ++ y ++ ", " ++ z ++ ")"
jlOp DoubleExp [x] = "exp(" ++ x ++ ")"
jlOp DoubleLog [x] = "_idris_log(" ++ x ++ ")"
jlOp DoublePow [x, y] = "_idris_pow(" ++ x ++ ", " ++ y ++ ")"
jlOp DoubleSin [x] = "sin(" ++ x ++ ")"
jlOp DoubleCos [x] = "cos(" ++ x ++ ")"
jlOp DoubleTan [x] = "tan(" ++ x ++ ")"
jlOp DoubleASin [x] = "_idris_asin(" ++ x ++ ")"
jlOp DoubleACos [x] = "_idris_acos(" ++ x ++ ")"
jlOp DoubleATan [x] = "atan(" ++ x ++ ")"
jlOp DoubleSqrt [x] = "_idris_sqrt(" ++ x ++ ")"
jlOp DoubleFloor [x] = "floor(" ++ x ++ ")"
jlOp DoubleCeiling [x] = "ceil(" ++ x ++ ")"
jlOp (Cast from to) [x] = jlCast from to x
jlOp BelieveMe [_, _, x] = x
jlOp Crash [_, msg] = "_idris_crash(" ++ msg ++ ")"
jlOp op _ = "_idris_crash(" ++ jlString ("unimplemented primitive: " ++ show op) ++ ")"

--------------------------------------------------------------------------------
--          External primitives
--------------------------------------------------------------------------------

jlExtPrim : Name -> List String -> String
jlExtPrim nm args = case (dropAllNS nm, args) of
  (UN (Basic "prim__newIORef"), [_, v, _]) => "_idris_newIORef(" ++ v ++ ")"
  (UN (Basic "prim__readIORef"), [_, r, _]) => "_idris_readIORef(" ++ r ++ ")"
  (UN (Basic "prim__writeIORef"), [_, r, v, _]) => "_idris_writeIORef(" ++ r ++ ", " ++ v ++ ")"
  (UN (Basic "prim__newArray"), [_, n, v, _]) => "_idris_newArray(" ++ n ++ ", " ++ v ++ ")"
  (UN (Basic "prim__arrayGet"), [_, a, i, _]) => "_idris_arrayGet(" ++ a ++ ", " ++ i ++ ")"
  (UN (Basic "prim__arraySet"), [_, a, i, v, _]) => "_idris_arraySet(" ++ a ++ ", " ++ i ++ ", " ++ v ++ ")"
  (UN (Basic "prim__getChar"), [w]) => "read(stdin, Char)"
  (UN (Basic "prim__os"), []) => "_idris_os()"
  (UN (Basic "prim__codegen"), []) => jlString "julia"
  _ => "_idris_crash(" ++ jlString ("unimplemented primitive: " ++ show nm) ++ ")"

--------------------------------------------------------------------------------
--          Code generation
--------------------------------------------------------------------------------

scName : Nat -> String
scName i = "_sc" ++ show i

jlBind : List (String, String) -> String -> String
jlBind [] body = body
jlBind bs body =
  "let " ++ showSep ", " (map (\(n, v) => n ++ " = " ++ v) bs) ++ "\n" ++
  body ++ "\nend"

mkFields : Nat -> String -> List Name -> List (String, String)
mkFields _ _ [] = []
mkFields base scrut (n :: ns) =
  (jlName n, scrut ++ "[" ++ show base ++ "]") :: mkFields (base + 1) scrut ns

||| Field bindings for a `Val` constructor (fields are `scrut.args[i]`).
mkValFields : Nat -> String -> List Name -> List (String, String)
mkValFields _ _ [] = []
mkValFields base scrut (n :: ns) =
  (jlName n, scrut ++ ".args[" ++ show base ++ "]") :: mkValFields (base + 1) scrut ns

buildIfChain : List (String, String) -> String -> String
buildIfChain [] def = def
buildIfChain ((c, b) :: rest) def =
  "if " ++ c ++ "\n" ++ b ++ "\n" ++ chain rest ++ "end\n"
  where
    chain : List (String, String) -> String
    chain [] = "else\n" ++ def ++ "\n"
    chain ((c, b) :: rest) = "elseif " ++ c ++ "\n" ++ b ++ "\n" ++ chain rest

mutual
  jlExp : Nat -> NamedCExp -> Core String
  jlExp i (NmLocal _ n) = pure $ jlName n
  jlExp i (NmRef _ n) = pure $ jlRefName n
  jlExp i (NmLam _ x sc) = do
    b <- jlExp i sc
    pure $ "(@nospecialize " ++ jlName x ++ ") -> " ++ b
  jlExp i (NmLet _ x val sc) = do
    v <- jlExp i val
    b <- jlExp i sc
    pure $ "let " ++ jlName x ++ " = " ++ v ++ "\n" ++ b ++ "\nend"
  jlExp i (NmApp _ f args) = do
    f' <- jlExp i f
    args' <- traverse (jlExp i) args
    pure $ "(" ++ f' ++ ")(" ++ showSep ", " args' ++ ")"
  jlExp i (NmCon _ _ UNIT _ []) = pure "nothing"
  jlExp i (NmCon _ n RECORD _ args) = do
    args' <- traverse (jlExp i) args
    pure $ jlTuple args'
  jlExp i (NmCon _ n ci tag args) = do
    args' <- traverse (jlExp i) args
    pure $ "Val(" ++ jlTag n tag ++ ", " ++ jlTuple args' ++ ")"
  jlExp i (NmOp _ op args) = do
    args' <- traverseVect (jlExp i) args
    pure $ jlOp op args'
  jlExp i (NmExtPrim _ p args) = do
    args' <- traverse (jlExp i) args
    pure $ jlExtPrim p args'
  jlExp i (NmDelay _ _ x) = do
    x' <- jlExp i x
    pure $ "() -> " ++ x'
  jlExp i (NmForce _ _ x) = do
    x' <- jlExp i x
    pure $ "(" ++ x' ++ ")()"
  jlExp i (NmConCase _ sc alts def) = do
    scode <- jlExp (i + 1) sc
    let n = scName i
    body <- jlConCase (i + 1) n alts def
    pure $ "let " ++ n ++ " = " ++ scode ++ "\n" ++ body ++ "\nend"
  jlExp i (NmConstCase _ sc alts def) = do
    scode <- jlExp (i + 1) sc
    let n = scName i
    body <- jlConstCase (i + 1) n alts def
    pure $ "let " ++ n ++ " = " ++ scode ++ "\n" ++ body ++ "\nend"
  jlExp i (NmPrimVal _ c) = pure $ jlConstant c
  jlExp i (NmErased _) = pure "nothing"
  jlExp i (NmCrash _ msg) = pure $ "_idris_crash(" ++ jlString msg ++ ")"

  jlConCase : Nat -> String -> List NamedConAlt -> Maybe NamedCExp -> Core String
  jlConCase i scrut [] Nothing = pure $ "_idris_crash(\"Case not covered\")"
  jlConCase i scrut [] (Just def) = jlExp i def
  jlConCase i scrut [MkNConAlt _ RECORD _ args body] Nothing = do
    b <- jlExp i body
    pure $ jlBind (mkFields 1 scrut args) b
  jlConCase i scrut [MkNConAlt n ci tag args body] Nothing = do
    b <- jlExp i body
    pure $ jlBind (mkValFields 1 scrut args) b
  jlConCase i scrut alts def = do
    branches <- traverse (jlConAlt i scrut) alts
    defc <- traverseOpt (jlExp i) def
    pure $ buildIfChain branches
             (fromMaybe "_idris_crash(\"Case not covered\")" defc)

  jlConAlt : Nat -> String -> NamedConAlt -> Core (String, String)
  jlConAlt i scrut (MkNConAlt n ci tag args body) = do
    b <- jlExp i body
    let b' = jlBind (mkValFields 1 scrut args) b
    pure (scrut ++ ".tag == " ++ jlTag n tag, b')

  jlConstCase : Nat -> String -> List NamedConstAlt -> Maybe NamedCExp -> Core String
  jlConstCase i scrut [] Nothing = pure $ "_idris_crash(\"Case not covered\")"
  jlConstCase i scrut alts def = do
    branches <- traverse (jlConstAlt i scrut) alts
    defc <- traverseOpt (jlExp i) def
    pure $ buildIfChain branches
             (fromMaybe "_idris_crash(\"Case not covered\")" defc)

  jlConstAlt : Nat -> String -> NamedConstAlt -> Core (String, String)
  jlConstAlt i scrut (MkNConstAlt c body) = do
    b <- jlExp i body
    pure (scrut ++ " == " ++ jlConstant c, b)

jlFun : Function -> Core String
jlFun (MkFunction n args body) = do
  b <- jlExp 0 body
  pure $ "function " ++ jlName n ++ "(" ++
         showSep ", " (map (\a => "@nospecialize(" ++ jlName a ++ ")") args) ++ ")\n" ++
         b ++ "\nend\n"

jlErrorDef : (Name, FC, NamedDef) -> Core String
jlErrorDef (n, _, MkNmError _) = pure $
  "function " ++ jlName n ++ "(args...)\n    _idris_crash(" ++
  jlString ("unimplemented hole: " ++ show n) ++ ")\nend\n"
jlErrorDef _ = pure ""

--------------------------------------------------------------------------------
--          Foreign function interface
--------------------------------------------------------------------------------

data LoadedSupport : Type where

stripColon : String -> String
stripColon s = case strM s of
  StrCons _ t => t
  StrNil => ""

notWorld : CFType -> Bool
notWorld CFWorld = False
notWorld _ = True

indexFrom : Nat -> List a -> List (Nat, a)
indexFrom _ [] = []
indexFrom i (x :: xs) = (i, x) :: indexFrom (i + 1) xs

||| Find the first `julia:` FFI specifier, splitting only on the first colon
||| so that inline lambdas may contain commas and colons.
findJuliaFFI : List String -> Maybe String
findJuliaFFI [] = Nothing
findJuliaFFI (s :: ss) =
  case break (== ':') s of
    ("julia", rest) => Just (stripColon rest)
    _ => findJuliaFFI ss

||| Julia implementations for a few core Prelude IO primitives, so that basic
||| programs can run without requiring the standard library to be modified.
jlCoreForeign : Name -> Maybe String
jlCoreForeign n = case dropAllNS n of
  UN (Basic "prim__putStr") => Just $
    "function " ++ jlName n ++ "(@nospecialize(s), @nospecialize(w))\n    print(s)\n    return nothing\nend\n"
  UN (Basic "prim__putChar") => Just $
    "function " ++ jlName n ++ "(@nospecialize(c), @nospecialize(w))\n    print(c)\n    return nothing\nend\n"
  UN (Basic "prim__getStr") => Just $
    "function " ++ jlName n ++ "(@nospecialize(w))\n    return readline()\nend\n"
  UN (Basic "prim__getEnv") => Just $
    "function " ++ jlName n ++ "(@nospecialize(k), @nospecialize(w))\n    return get(ENV, k, nothing)\nend\n"
  UN (Basic "prim__setEnv") => Just $
    "function " ++ jlName n ++ "(@nospecialize(k), @nospecialize(v), @nospecialize(o), @nospecialize(w))\n    if !(o == 0 && haskey(ENV, k))\n        ENV[k] = v\n    end\n    return Int64(0)\nend\n"
  UN (Basic "prim__unsetEnv") => Just $
    "function " ++ jlName n ++ "(@nospecialize(k), @nospecialize(w))\n    delete!(ENV, k)\n    return Int64(0)\nend\n"
  UN (Basic "prim__getPID") => Just $
    "function " ++ jlName n ++ "(@nospecialize(w))\n    return Int64(getpid())\nend\n"
  UN (Basic "prim__getString") => Just $
    "function " ++ jlName n ++ "(@nospecialize(p))\n    return p\nend\n"
  UN (Basic "prim__nullAnyPtr") => Just $
    "function " ++ jlName n ++ "(@nospecialize(p))\n    return Int64(p === nothing ? 1 : 0)\nend\n"
  UN (Basic "prim__makeMutex") => Just $
    "function " ++ jlName n ++ "(@nospecialize(w))\n    return ReentrantLock()\nend\n"
  UN (Basic "prim__mutexAcquire") => Just $
    "function " ++ jlName n ++ "(@nospecialize(m), @nospecialize(w))\n    lock(m)\n    return nothing\nend\n"
  UN (Basic "prim__mutexRelease") => Just $
    "function " ++ jlName n ++ "(@nospecialize(m), @nospecialize(w))\n    unlock(m)\n    return nothing\nend\n"
  UN (Basic "prim__fork") => Just $
    "function " ++ jlName n ++ "(@nospecialize(prog), @nospecialize(w))\n    return Threads.@spawn prog(w)\nend\n"
  UN (Basic "prim__threadWait") => Just $
    "function " ++ jlName n ++ "(@nospecialize(t), @nospecialize(w))\n    wait(t)\n    return nothing\nend\n"
  UN (Basic "fastUnpack") => Just $
    "function " ++ jlName n ++ "(@nospecialize(s))\n    return _idris_fastUnpack(s)\nend\n"
  UN (Basic "fastPack") => Just $
    "function " ++ jlName n ++ "(@nospecialize(xs))\n    return _idris_fastPack(xs)\nend\n"
  UN (Basic "fastConcat") => Just $
    "function " ++ jlName n ++ "(@nospecialize(xs))\n    return _idris_fastConcat(xs)\nend\n"
  _ => Nothing

loadSupport : {auto c : Ref Ctxt Defs} ->
              {auto ls : Ref LoadedSupport (List String)} ->
              String -> Core String
loadSupport file = do
  loaded <- get LoadedSupport
  if file `elem` loaded
     then pure ""
     else do
       put LoadedSupport (file :: loaded)
       readDataFile ("jl/" ++ file ++ ".jl")

jlForeignSpec : {auto c : Ref Ctxt Defs} ->
                {auto ls : Ref LoadedSupport (List String)} ->
                Name -> List CFType -> String -> Core (String, String)
jlForeignSpec n fargs spec =
  case break (== ':') spec of
    ("lambda", rest) =>
      let expr = stripColon rest
          numbered = indexFrom 0 fargs
          allNames = map (\i => "@nospecialize(_a" ++ show i ++ ")") (map fst numbered)
          realNames = map (\i => "_a" ++ show i)
                          (map fst (filter (notWorld . snd) numbered))
          body = "(" ++ expr ++ ")(" ++ showSep ", " realNames ++ ")"
      in pure ("", "function " ++ jlName n ++ "(" ++ showSep ", " allNames ++ ")\n" ++
                    "    return " ++ body ++ "\nend\n")
    ("support", rest) =>
      case break (== ',') (stripColon rest) of
        (fn, file) => do
          sup <- loadSupport file
          let numbered = indexFrom 0 fargs
              allNames = map (\i => "@nospecialize(_a" ++ show i ++ ")") (map fst numbered)
              realNames = map (\i => "_a" ++ show i)
                              (map fst (filter (notWorld . snd) numbered))
              body = file ++ "_" ++ fn ++ "(" ++ showSep ", " realNames ++ ")"
          pure (sup ++ "\n",
                "function " ++ jlName n ++ "(" ++ showSep ", " allNames ++ ")\n" ++
                "    return " ++ body ++ "\nend\n")
    _ => throw (InternalError ("bad julia FFI: " ++ spec))

jlForeign : {auto c : Ref Ctxt Defs} ->
            {auto ls : Ref LoadedSupport (List String)} ->
            (Name, FC, NamedDef) -> Core (String, String)
jlForeign (n, _, MkNmForeign ccs fargs ret) =
  case jlCoreForeign n of
    Just decl => pure ("", decl)
    Nothing =>
      case findJuliaFFI ccs of
        Just spec => jlForeignSpec n fargs spec
        Nothing => pure ("", "function " ++ jlName n ++ "(args...)\n    _idris_crash(" ++
                        jlString ("foreign function not implemented for julia: " ++ show n) ++
                        ")\nend\n")
jlForeign _ = pure ("", "")

--------------------------------------------------------------------------------
--          Driver
--------------------------------------------------------------------------------

isUserTopLevelName : Name -> Bool
isUserTopLevelName (NS _ n) = isUserTopLevelName n
isUserTopLevelName (UN _) = True
isUserTopLevelName _ = False

||| Emit clean (un-mangled) aliases for top level user functions, so that
||| e.g. `Main.square` is available as `square` in the generated module.
cleanAliases : List (Name, FC, NamedDef) -> String
cleanAliases defs =
  fastConcat (map (\(a, m) => a ++ " = " ++ m ++ "\n")
                  (nub (mapMaybe alias defs)))
  where
    alias : (Name, FC, NamedDef) -> Maybe (String, String)
    alias (n, _, MkNmFun _ _) =
      if isUserTopLevelName n && nameRoot n /= "main"
         then let a = jlKeywordSafe (jlSafe (nameRoot n)) in
              if a == jlName n
                 then Nothing
                 else Just (a, jlName n)
         else Nothing
    alias _ = Nothing

emitJulia : {auto c : Ref Ctxt Defs} -> CompileData -> Core String
emitJulia cdata = do
  let mainName = MN "__mainExpression" 0
  let baseDefs = namedDefs cdata
  let allDefs = (mainName, EmptyFC, MkNmFun [] (forget (mainExpr cdata)))
                  :: baseDefs
  let funs = TailRec.functions (UN $ Basic "__tailRec") allDefs
  funDecls <- fastConcat <$> traverse jlFun funs
  ls <- newRef {t = List String} LoadedSupport []
  fes <- traverse jlForeign baseDefs
  let supCode = fastConcat (map fst fes)
  let fdecls = fastConcat (map snd fes)
  errDecls <- fastConcat <$> traverse jlErrorDef baseDefs
  let mainAlias = "main() = " ++ jlName mainName ++ "()\n"
  let aliases = cleanAliases baseDefs
  let body = juliaRuntime ++ "\n" ++ supCode ++ "\n" ++ fdecls ++ "\n" ++
             errDecls ++ "\n" ++ funDecls ++ "\n" ++ mainAlias ++ aliases
  pure $ "module IdrisMain\n\n" ++ body ++ "\nend\n"

compileToJulia : Ref Ctxt Defs -> Ref Syn SyntaxInfo -> ClosedTerm -> Core String
compileToJulia c s tm = do
  cdata <- getCompileDataWith ["julia"] False Cases tm
  emitJulia cdata

findJulia : IO String
findJulia = do
  Nothing <- getEnv "JULIA"
    | Just j => pure j
  path <- pathLookup ["julia"]
  pure $ fromMaybe "/usr/bin/env julia" path

compileExpr : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
              (tmpDir : String) -> (outputDir : String) ->
              ClosedTerm -> (outfile : String) -> Core (Maybe String)
compileExpr c s tmpDir outputDir tm outfile = do
  code <- compileToJulia c s tm
  let out = if toLower (fromMaybe "" (extension outfile)) == "jl"
               then outputDir </> outfile
               else outputDir </> outfile ++ ".jl"
  Core.writeFile out code
  pure (Just out)

executeExpr : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
              (tmpDir : String) -> ClosedTerm -> Core ()
executeExpr c s tmpDir tm = do
  code <- compileToJulia c s tm
  let outn = tmpDir </> "_tmp_julia.jl"
  Core.writeFile outn code
  julia <- coreLift findJulia
  let run = "include(" ++ jlString outn ++ "); IdrisMain.main()"
  0 <- coreLift $ system [julia, "-e", run]
    | status => throw (InternalError ("Julia exited with return code " ++ show status))
  pure ()

||| Codegen for the Julia backend.
export
codegenJulia : Codegen
codegenJulia = MkCG compileExpr executeExpr Nothing Nothing
