{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 - Initial Verilog AST Author: Tom Hawkins <tomahawkins@gmail.com>
 -
 - SystemVerilog top-level items (descriptions, package items)
 -}

module Language.SystemVerilog.AST.Description
    ( Description (..)
    , PackageItem (..)
    , PartKW      (..)
    , Lifetime    (..)
    ) where

import Text.Printf (printf)

import Language.SystemVerilog.AST.ShowHelp

import Language.SystemVerilog.AST.Attr (Attr)
import Language.SystemVerilog.AST.Decl (Decl)
import Language.SystemVerilog.AST.Stmt (Stmt)
import Language.SystemVerilog.AST.Type (Type, Identifier)
import {-# SOURCE #-} Language.SystemVerilog.AST.ModuleItem (ModuleItem)

data Description
    = Part [Attr] Bool PartKW Lifetime Identifier [Identifier] [ModuleItem]
    | PackageItem PackageItem
    | Package Lifetime Identifier [PackageItem]
    | Class   Lifetime Identifier [Decl] [PackageItem]
    deriving Eq

instance Show Description where
    showList l _ = unlines' $ map show l
    show (Part attrs True  kw lifetime name _ items) =
        printf "%sextern %s %s%s %s;"
            (concatMap showPad attrs)
            (show kw) (showPad lifetime) name (indentedParenList itemStrs)
        where itemStrs = map (init . show) items
    show (Part attrs False kw lifetime name ports items) =
        printf "%s%s %s%s%s;\n%s\nend%s"
            (concatMap showPad attrs)
            (show kw) (showPad lifetime) name portsStr bodyStr (show kw)
        where
            portsStr = if null ports
                then ""
                else " " ++ indentedParenList ports
            bodyStr = indent $ unlines' $ map show items
    show (Package lifetime name items) =
        printf "package %s%s;\n%s\nendpackage"
            (showPad lifetime) name bodyStr
        where
            bodyStr = indent $ unlines' $ map show items
    show (Class lifetime name decls items) =
        printf "class %s%s;\n%s\nendclass"
            (showPad lifetime) name bodyStr
        where
            bodyStr = indent $ unlines' $ map show items'
            items' = (map Decl decls) ++ items
    show (PackageItem i) = show i

data PackageItem
    = Function Lifetime Type Identifier [Decl] [Stmt]
    | Task     Lifetime      Identifier [Decl] [Stmt]
    | Import Identifier Identifier
    | Export Identifier Identifier
    | Decl Decl
    | Directive String
    deriving Eq

instance Show PackageItem where
    show (Function ml t x i b) =
        printf "function %s%s%s;\n%s\nendfunction" (showPad ml) (showPad t) x
        (showBlock i b)
    show (Task ml x i b) =
        printf "task %s%s;\n%s\nendtask"
            (showPad ml) x (showBlock i b)
    show (Import x y) = printf "import %s::%s;" x (showWildcard y)
    show (Export x y) = printf "export %s::%s;" (showWildcard x) (showWildcard y)
    show (Decl decl) = show decl
    show (Directive str) = str

showWildcard :: Identifier -> String
showWildcard "" = "*"
showWildcard x = x

data PartKW
    = Module
    | Interface
    deriving Eq

instance Show PartKW where
    show Module    = "module"
    show Interface = "interface"

data Lifetime
    = Static
    | Automatic
    | Inherit
    deriving Eq

instance Show Lifetime where
    show Static    = "static"
    show Automatic = "automatic"
    show Inherit   = ""
