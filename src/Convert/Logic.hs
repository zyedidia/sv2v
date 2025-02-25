{- sv2v
 - Author: Zachary Snow <zach@zachjs.com>
 -
 - Conversion from `logic` to `wire` or `reg`
 -
 - We convert a module-level logic to a reg if it is assigned to in an always or
 - initial block. Other module-level logics become wires. All other logics
 - (i.e., in a function) become regs.
 -
 - Parameters and localparams with integer vector types become implicit.
 -
 - The struct conversion and Verilog-2005's lack of permissive net vs. variable
 - resolution leads to some interesting special cases for this conversion, as
 - parts of a struct may be used as a variable, while other parts may be used as
 - a net.
 -
 - 1) If a reg, or a portion thereof, is assigned by a continuous assignment
 - item, then that assignment is converted to a procedural assignment within an
 - added `always_comb` item.
 -
 - 2) If a reg, or a portion thereof, is bound to an output port, then that
 - binding is replaced by a temporary net declaration, and a procedural
 - assignment is added which updates the reg to the value of the new net.
 -}

module Convert.Logic (convert) where

import Control.Monad.State.Strict
import Control.Monad.Writer.Strict
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Convert.Scoper
import Convert.Traverse
import Language.SystemVerilog.AST

type Ports = Map.Map Identifier [(Identifier, Direction)]
type Location = [Identifier]
type Locations = Set.Set Location
type ST = ScoperT Type (State Locations)

convert :: [AST] -> [AST]
convert =
    traverseFiles
        (collectDescriptionsM collectPortsM)
        (traverseDescriptions . convertDescription)
    where
        collectPortsM :: Description -> Writer Ports ()
        collectPortsM (orig @ (Part _ _ _ _ name portNames _)) =
            tell $ Map.singleton name ports
            where
                ports = zip portNames (map lookupDir portNames)
                dirs = execWriter $ collectModuleItemsM collectDeclDirsM orig
                lookupDir :: Identifier -> Direction
                lookupDir portName =
                    case lookup portName dirs of
                        Just dir -> dir
                        Nothing -> Inout
        collectPortsM _ = return ()
        collectDeclDirsM :: ModuleItem -> Writer [(Identifier, Direction)] ()
        collectDeclDirsM (MIPackageItem (Decl (Variable dir t ident _ _))) =
            case (dir, t) of
                (_, InterfaceT{}) -> tell [(ident, Local)]
                (Local, _) -> return ()
                _ -> tell [(ident, dir)]
        collectDeclDirsM _ = return ()

convertDescription :: Ports -> Description -> Description
convertDescription ports (description @ (Part _ _ Module _ _ _ _)) =
    evalState (operation description) Set.empty
    where
        operation =
            -- log then rewrite
            partScoperT td tm tg ts >=>
            partScoperT rd tm tg ts
        td = traverseDeclM
        rd = rewriteDeclM
        tm = traverseModuleItemM ports
        tg = traverseGenItemM
        ts = traverseStmtM
convertDescription _ other = other

traverseGenItemM :: GenItem -> ST GenItem
traverseGenItemM = return

traverseModuleItemM :: Ports -> ModuleItem -> ST ModuleItem
traverseModuleItemM ports = embedScopes $ traverseModuleItem ports

traverseModuleItem :: Ports -> Scopes Type -> ModuleItem -> ModuleItem
traverseModuleItem ports scopes =
    fixModuleItem
    where
        isReg :: LHS -> Bool
        isReg =
            or . execWriter . collectNestedLHSsM isReg'
            where
                isRegType :: Type -> Bool
                isRegType (IntegerVector TReg _ _) = True
                isRegType _ = False
                isReg' :: LHS -> Writer [Bool] ()
                isReg' lhs =
                    case lookupElem scopes lhs of
                        Just (_, _, t) -> tell [isRegType t]
                        _ -> tell [False]

        always_comb = AlwaysC Always . Timing (Event SenseStar)

        fixModuleItem :: ModuleItem -> ModuleItem
        -- rewrite bad continuous assignments to use procedural assignments
        fixModuleItem (Assign AssignOptionNone lhs expr) =
            if not (isReg lhs)
                then Assign AssignOptionNone lhs expr
                else
                    Generate $ map GenModuleItem
                    [ MIPackageItem (Decl (Variable Local t x [] Nil))
                    , Assign AssignOptionNone (LHSIdent x) expr
                    , always_comb $ Asgn AsgnOpEq Nothing lhs (Ident x)
                    ]
            where
                t = Net (NetType TWire) Unspecified
                        [(DimsFn FnBits $ Right $ lhsToExpr lhs, RawNum 1)]
                x = "sv2v_tmp_" ++ shortHash (lhs, expr)
        -- rewrite port bindings to use temporary nets where necessary
        fixModuleItem (Instance moduleName params instanceName rs bindings) =
            if null newItems
                then Instance moduleName params instanceName rs bindings
                else Generate $ map GenModuleItem $
                    comment : newItems ++
                    [Instance moduleName params instanceName rs bindings']
            where
                comment = MIPackageItem $ Decl $ CommentDecl
                    "rewrote reg-to-output bindings"
                (bindings', newItemsList) = unzip $ map fixBinding bindings
                newItems = concat newItemsList
                fixBinding :: PortBinding -> (PortBinding, [ModuleItem])
                fixBinding (portName, expr) =
                    if not outputBound || not usesReg
                        then ((portName, expr), [])
                        else ((portName, tmpExpr), items)
                    where
                        outputBound = portDir == Just Output
                        usesReg = Just True == fmap isReg (exprToLHS expr)
                        portDir = maybeModulePorts >>= lookup portName
                        tmp = "sv2v_tmp_" ++ instanceName ++ "_" ++ portName
                        tmpExpr = Ident tmp
                        t = Net (NetType TWire) Unspecified
                                [(DimsFn FnBits $ Right expr, RawNum 1)]
                        items =
                            [ MIPackageItem $ Decl $ Variable Local t tmp [] Nil
                            , always_comb $ Asgn AsgnOpEq Nothing lhs tmpExpr]
                        lhs = case exprToLHS expr of
                            Just l -> l
                            Nothing ->
                                error $ "bad non-lhs, non-net expr "
                                    ++ show expr ++ " connected to output port "
                                    ++ portName ++ " of " ++ instanceName
                maybeModulePorts = Map.lookup moduleName ports
        fixModuleItem other = other

traverseDeclM :: Decl -> ST Decl
traverseDeclM (decl @ (Variable _ t x _ _)) =
    insertElem x t >> return decl
traverseDeclM decl = return decl

rewriteDeclM :: Decl -> ST Decl
rewriteDeclM (Variable d t x a e) = do
    (d', t') <- case t of
        IntegerVector TLogic sg rs -> do
            insertElem x t
            details <- lookupElemM x
            let Just (accesses, _, _) = details
            let location = map accessName accesses
            usedAsReg <- lift $ gets $ Set.member location
            blockLogic <- withinProcedureM
            if usedAsReg || blockLogic
                then do
                    let dir = if d == Inout then Output else d
                    return (dir, IntegerVector TReg sg rs)
                else return (d, Net (NetType TWire) sg rs)
        _ -> return (d, t)
    insertElem x t'
    return $ Variable d' t' x a e
rewriteDeclM (Param s (IntegerVector _ sg []) x e) =
    return $ Param s (Implicit sg [(zero, zero)]) x e
    where zero = RawNum 0
rewriteDeclM (Param s (IntegerVector _ sg rs) x e) =
    return $ Param s (Implicit sg rs) x e
rewriteDeclM decl = return decl

traverseStmtM :: Stmt -> ST Stmt
traverseStmtM (Timing timing stmt) =
    -- ignore the timing LHSs
    return $ Timing timing stmt
traverseStmtM (Subroutine (Ident f) args) = do
    case args of
        Args [_, Ident x, _] [] ->
            if f == "$readmemh" || f == "$readmemb"
                then collectLHSM $ LHSIdent x
                else return ()
        _ -> return ()
    return $ Subroutine (Ident f) args
traverseStmtM stmt = do
    collectStmtLHSsM (collectNestedLHSsM collectLHSM) stmt
    return stmt

collectLHSM :: LHS -> ST ()
collectLHSM lhs = do
    details <- lookupElemM lhs
    case details of
        Just (accesses, _, _) -> do
            let location = map accessName accesses
            lift $ modify $ Set.insert location
        Nothing -> return ()
