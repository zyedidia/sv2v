{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 - Initial Verilog AST Author: Tom Hawkins <tomahawkins@gmail.com>
 -
 - SystemVerilog types
 -}

module Language.SystemVerilog.AST.Type
    ( Identifier
    , Field
    , Type               (..)
    , Signing            (..)
    , Packing            (..)
    , NetType            (..)
    , IntegerVectorType  (..)
    , IntegerAtomType    (..)
    , NonIntegerType     (..)
    , NetTypeAndStrength (..)
    , DriveStrength      (..)
    , Strength0          (..)
    , Strength1          (..)
    , ChargeStrength     (..)
    , pattern UnknownType
    , typeRanges
    , elaborateIntegerAtom
    ) where

import Text.Printf (printf)

import Language.SystemVerilog.AST.Expr
import Language.SystemVerilog.AST.ShowHelp

type Identifier = String

type Item = (Identifier, Expr)
type Field = (Type, Identifier)

data Type
    = IntegerVector IntegerVectorType  Signing [Range]
    | IntegerAtom   IntegerAtomType    Signing
    | NonInteger    NonIntegerType
    | Net           NetTypeAndStrength Signing [Range]
    | Implicit                         Signing [Range]
    | Alias               Identifier           [Range]
    | PSAlias  Identifier Identifier           [Range]
    | CSAlias  Identifier [ParamBinding] Identifier [Range]
    | Enum     Type         [Item]             [Range]
    | Struct   Packing      [Field]            [Range]
    | Union    Packing      [Field]            [Range]
    | InterfaceT Identifier Identifier         [Range]
    | TypeOf Expr
    | TypedefRef Expr
    | UnpackedType Type [Range] -- used internally
    deriving (Eq, Ord)

instance Show Type where
    show (Alias         xx    rs) = printf "%s%s" xx (showRanges rs)
    show (PSAlias ps    xx    rs) = printf "%s::%s%s" ps xx (showRanges rs)
    show (CSAlias ps pm xx    rs) = printf "%s#%s::%s%s" ps (showParams pm) xx (showRanges rs)
    show (Net           kw sg rs) = printf "%s%s%s" (show kw) (showPadBefore sg) (showRanges rs)
    show (Implicit         sg rs) = printf "%s%s"             (showPad       sg) (dropWhile (== ' ') $ showRanges rs)
    show (IntegerVector kw sg rs) = printf "%s%s%s" (show kw) (showPadBefore sg) (showRanges rs)
    show (IntegerAtom   kw sg   ) = printf "%s%s"   (show kw) (showPadBefore sg)
    show (NonInteger    kw      ) = printf "%s"     (show kw)
    show (InterfaceT "" "" r) = "interface" ++ showRanges r
    show (InterfaceT x y r) = x ++ yStr ++ (showRanges r)
        where yStr = if null y then "" else '.' : y
    show (Enum t vals r) = printf "enum %s{%s}%s" tStr (commas $ map showVal vals) (showRanges r)
        where
            tStr = showPad t
            showVal :: (Identifier, Expr) -> String
            showVal (x, e) = x ++ (showAssignment e)
    show (Struct p items r) = printf "struct %s{\n%s\n}%s" (showPad p) (showFields items) (showRanges r)
    show (Union  p items r) = printf  "union %s{\n%s\n}%s" (showPad p) (showFields items) (showRanges r)
    show (TypeOf expr) = printf "type(%s)" (show expr)
    show (UnpackedType t rs) = printf "UnpackedType(%s, %s)" (show t) (showRanges rs)
    show (TypedefRef e) = show e

showFields :: [Field] -> String
showFields items = itemsStr
    where
        itemsStr = indent $ unlines' $ map showItem items
        showItem (t, x) = printf "%s %s;" (show t) x

-- internal representation of a fully implicit or unknown type
pattern UnknownType :: Type
pattern UnknownType = Implicit Unspecified []

instance Show ([Range] -> Type) where
    show tf = show (tf [])
instance Eq ([Range] -> Type) where
    (==) tf1 tf2 = (tf1 []) == (tf2 [])

instance Show (Signing -> [Range] -> Type) where
    show tf = show (tf Unspecified)
instance Eq (Signing -> [Range] -> Type) where
    (==) tf1 tf2 = (tf1 Unspecified) == (tf2 Unspecified)

typeRanges :: Type -> ([Range] -> Type, [Range])
typeRanges typ =
    case typ of
        Net           kw sg rs -> (Net           kw sg, rs)
        Implicit         sg rs -> (Implicit         sg, rs)
        IntegerVector kw sg rs -> (IntegerVector kw sg, rs)
        Enum            t v rs -> (Enum            t v, rs)
        Struct          p l rs -> (Struct          p l, rs)
        Union           p l rs -> (Union           p l, rs)
        InterfaceT      x y rs -> (InterfaceT      x y, rs)
        Alias            xx rs -> (Alias            xx, rs)
        PSAlias    ps    xx rs -> (PSAlias    ps    xx, rs)
        CSAlias    ps pm xx rs -> (CSAlias    ps pm xx, rs)
        UnpackedType  t     rs -> (UnpackedType      t, rs)
        IntegerAtom   kw sg    -> (nullRange $ IntegerAtom kw sg, [])
        NonInteger    kw       -> (nullRange $ NonInteger  kw   , [])
        TypeOf            expr -> (nullRange $ TypeOf       expr, [])
        TypedefRef        expr -> (nullRange $ TypedefRef   expr, [])

nullRange :: Type -> ([Range] -> Type)
nullRange t [] = t
nullRange t [(RawNum 0, RawNum 0)] = t
nullRange (IntegerAtom TInteger sg) rs =
    -- integer arrays are allowed in SystemVerilog but not in Verilog
    IntegerVector TBit sg' (rs ++ [(RawNum 31, RawNum 0)])
    where sg' = if sg == Unsigned then Unsigned else Signed
nullRange t rs1 =
    if t == t'
        then error $ "non-vector type " ++ show t ++
                " cannot have packed dimesions:" ++ show rs1
        else tf $ rs1 ++ rs2
    where
        t' = elaborateIntegerAtom t
        (tf, rs2) = typeRanges t'

elaborateIntegerAtom :: Type -> Type
elaborateIntegerAtom (IntegerAtom TInt      sg) = baseIntType sg Signed 32
elaborateIntegerAtom (IntegerAtom TShortint sg) = baseIntType sg Signed 16
elaborateIntegerAtom (IntegerAtom TLongint  sg) = baseIntType sg Signed 64
elaborateIntegerAtom (IntegerAtom TByte     sg) = baseIntType sg Signed  8
elaborateIntegerAtom other = other

-- makes a integer "compatible" type with the given signing, base signing and
-- size; if not unspecified, the first signing overrides the second
baseIntType :: Signing -> Signing -> Int -> Type
baseIntType sgOverride sgBase size =
    IntegerVector TLogic sg [(RawNum hi, RawNum 0)]
    where
        hi = fromIntegral $ size - 1
        sg = if sgOverride /= Unspecified
                then sgOverride
                else sgBase

data Signing
    = Unspecified
    | Signed
    | Unsigned
    deriving (Eq, Ord)

instance Show Signing where
    show Unspecified = ""
    show Signed = "signed"
    show Unsigned = "unsigned"

data NetType
    = TSupply0
    | TSupply1
    | TTri
    | TTriand
    | TTrior
    | TTrireg
    | TTri0
    | TTri1
    | TUwire
    | TWire
    | TWand
    | TWor
    deriving (Eq, Ord)
data IntegerVectorType
    = TBit
    | TLogic
    | TReg
    deriving (Eq, Ord)
data IntegerAtomType
    = TByte
    | TShortint
    | TInt
    | TLongint
    | TInteger
    | TTime
    deriving (Eq, Ord)
data NonIntegerType
    = TShortreal
    | TReal
    | TRealtime
    | TString
    | TEvent
    deriving (Eq, Ord)

instance Show NetType where
    show TSupply0   = "supply0"
    show TSupply1   = "supply1"
    show TTri       = "tri"
    show TTriand    = "triand"
    show TTrior     = "trior"
    show TTrireg    = "trireg"
    show TTri0      = "tri0"
    show TTri1      = "tri1"
    show TUwire     = "uwire"
    show TWire      = "wire"
    show TWand      = "wand"
    show TWor       = "wor"
instance Show IntegerVectorType where
    show TBit       = "bit"
    show TLogic     = "logic"
    show TReg       = "reg"
instance Show IntegerAtomType where
    show TByte      = "byte"
    show TShortint  = "shortint"
    show TInt       = "int"
    show TLongint   = "longint"
    show TInteger   = "integer"
    show TTime      = "time"
instance Show NonIntegerType where
    show TShortreal = "shortreal"
    show TReal      = "real"
    show TRealtime  = "realtime"
    show TString    = "string"
    show TEvent     = "event"

data Packing
    = Unpacked
    | Packed Signing
    deriving (Eq, Ord)

instance Show Packing where
    show (Unpacked) = ""
    show (Packed s) = "packed" ++ (showPadBefore s)

data NetTypeAndStrength
    = NetType       NetType
    | NetTypeDrive  NetType DriveStrength
    | NetTypeCharge NetType ChargeStrength
    deriving (Eq, Ord)

instance Show NetTypeAndStrength where
    show (NetType       nt   ) = show nt
    show (NetTypeDrive  nt ds) = printf "%s %s" (show nt) (show ds)
    show (NetTypeCharge nt cs) = printf "%s %s" (show nt) (show cs)

data DriveStrength
    = DriveStrength Strength0 Strength1
    deriving (Eq, Ord)

instance Show DriveStrength where
    show (DriveStrength s0 s1) = printf "(%s, %s)" (show s0) (show s1)

data Strength0
    = Supply0
    | Strong0
    | Pull0
    | Weak0
    | Highz0
    deriving (Eq, Ord)

instance Show Strength0 where
    show Supply0 = "supply0"
    show Strong0 = "strong0"
    show Pull0   = "pull0"
    show Weak0   = "weak0"
    show Highz0  = "highz0"

data Strength1
    = Supply1
    | Strong1
    | Pull1
    | Weak1
    | Highz1
    deriving (Eq, Ord)

instance Show Strength1 where
    show Supply1 = "supply1"
    show Strong1 = "strong1"
    show Pull1   = "pull1"
    show Weak1   = "weak1"
    show Highz1  = "highz1"

data ChargeStrength
    = Small
    | Medium
    | Large
    deriving (Eq, Ord)

instance Show ChargeStrength where
    show Small  = "(small)"
    show Medium = "(medium)"
    show Large  = "(large)"
