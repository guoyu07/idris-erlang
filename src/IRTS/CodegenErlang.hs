module IRTS.CodegenErlang (codegenErlang) where

import           Idris.Core.TT
import           IRTS.Lang
import           IRTS.CodegenCommon
import           IRTS.Defunctionalise

import           Control.Applicative ((<$>))
import           Control.Monad.Except
import           Control.Monad.Trans.State

import           Data.Char (isPrint, toUpper, isUpper, isLower, isDigit, isAlpha)
import           Data.List (intercalate, insertBy, partition)
import qualified Data.Map.Strict as Map
import           Data.Ord (comparing)

import           System.Directory (getPermissions, setPermissions, setOwnerExecutable)
import           System.Exit (exitSuccess,exitFailure)

import           Paths_idris_erlang (getDataFileName)

-- TODO: Exports
-- TODO: Constructors as Records?

-- Everything happens in here. I think. Wait, no, everything actually
-- happens in `generateErl`. This is just a bit of glue code.
codegenErlang :: CodeGenerator
codegenErlang ci = do let outfile = outputFile ci
                      eitherEcg <- runErlCodeGen generateErl (defunDecls ci) (exportDecls ci)
                      case eitherEcg of
                        Left err -> do putStrLn ("Error: " ++ err)
                                       exitFailure
                        Right ecg -> do data_dir <- getDataFileName "irts"
                                        let erlout = (header outfile data_dir) ++ (Map.elems . forms) ecg ++ [""]
                                        writeFile outfile ("\n" `intercalate` erlout)
                                        p <- getPermissions outfile
                                        setPermissions outfile $ setOwnerExecutable True p

                                        putStrLn ("Compilation Succeeded: " ++ outfile)
                                        exitSuccess

-- Erlang files have to have a `-module().` annotation that matches
-- their filename (without the extension). Given we're making this, we
-- should be curteous and give coders a warning that this file was
-- autogenerated, rather than hand-coded.
header :: String -> String -> [String]
header filename data_dir
  = ["%% -*- erlang -*-",
     "%%! -smp enable -pa " ++ data_dir ++ "",
     "%% Generated by the Idris -> Erlang Compiler (idris-erlang).",
     "",
     "-module(" ++ modulename ++ ").\n",
     "",
     "-mode(compile).    %% Escript",
     "-export([main/1]). %% Escript.",
     "",
     "-compile(nowarn_unused_function).", -- don't tell me off for not using a fun
     "-compile(nowarn_unused_vars).",     -- don't tell me off for not using a variable
     "",
     "-define(TRUE,  1).",
     "-define(FALSE, 0).",
     ""]
  where modulename = takeWhile (/='.') filename

-- Erlang Codegen State Monad
data ErlCodeGen = ECG {
  forms :: Map.Map (String,Int) String, -- name and arity to form
  decls :: [(Name,DDecl)],
  records :: [(Name,Int)],
  locals :: [[(Int, String)]],
  nextLocal :: [Int]
  } deriving (Show)

initECG :: ErlCodeGen
initECG = ECG { forms = Map.empty
              , decls = []
              , records = []
              , locals = []
              , nextLocal = [0]
              }

type ErlCG = StateT ErlCodeGen (ExceptT String IO)

runErlCodeGen :: ([(Name, DDecl)] -> [ExportIFace] -> ErlCG ()) -> [(Name,DDecl)] -> [ExportIFace] -> IO (Either String ErlCodeGen)
runErlCodeGen ecg ddecls eifaces = runExceptT $ execStateT (ecg ddecls eifaces) initECG

emitForm :: (String, Int) -> String -> ErlCG ()
emitForm fa form = modify (\ecg -> ecg { forms = Map.insert fa form (forms ecg)})

addRecord :: Name -> Int -> ErlCG ()
addRecord name arity = do records <- gets records
                          let records1 = insertBy (comparing fst) (name,arity) records
                          modify (\ecg -> ecg { records = records1 })

-- We want to be able to compare the length of constructor arguments
-- to the arity of that record constructor, so this returns the
-- arity. If we can't find the record, then -1 is alright to return,
-- as no list will have that length.
recordArity :: Name -> ErlCG Int
recordArity name = do records <- gets records
                      case lookup name records of
                       Just i  -> return i
                       Nothing -> return (-1)

isRecord :: Name -> Int -> ErlCG Bool
isRecord nm ar = do records <- gets records
                    case lookup nm records of
                     Just ar -> return True
                     _       -> return False

-- OMG Coping with Local variables is a struggle.
--
-- locals is the mapping from (Loc n) to the variable name of that
-- binding. nextLocal is the largest (Loc n) seen at that level of the
-- stack.

wipeScope :: ErlCG ()
wipeScope = modify (\ecg -> ecg { locals = []
                                , nextLocal = [0]})

popScope :: ErlCG ()
popScope = modify (\ecg -> ecg { locals = tail (locals ecg)
                               , nextLocal = tail (nextLocal ecg) })


pushScopeWithVars :: [String] -> ErlCG ()
pushScopeWithVars vars = modify (\ecg -> ecg { locals = (zipWith (,) [0..] vars):(locals ecg)
                                             , nextLocal = (length vars) + (head (nextLocal ecg)):(nextLocal ecg) })


inScope :: ErlCG a -> ErlCG a
inScope = inScopeWithVars []

inScopeWithVars :: [String] -> ErlCG a -> ErlCG a
inScopeWithVars vars p = do pushScopeWithVars vars
                            r <- p
                            popScope
                            return r

getVar :: LVar -> ErlCG String
getVar (Glob name) = return $ erlVar name
getVar (Loc i) = do ls <- gets (concat . locals)
                    case lookup i ls of
                     Just var -> return var
                     Nothing  -> throwError "Local Not Found. Oh Fuck."

{- The Code Generator:

Takes in a Name and a DDecl, and hopefully emits some Forms.

Some Definitions:

- Form : the syntax for top-level Erlang function in an Erlang module

- Module : a group of Erlang functions

- Record : Erlang has n-arity tuples, and they're used for
datastructures, in which case it's usual for the first element in the
tuple to be the name of the datastructure. We'll be using these for
most constructors.

More when I realise they're needed.

This first time I'm going to avoid special-casing anything. Later
there are some things I want to special-case to make Erlang interop
easier: - Lists; - 0-Arity Constructors to Atoms (DONE); - Pairs; -
Booleans; - Case Statements that operate only on arguments (erlang has
special syntax for this); - Using Library functions, not Idris' ones;

We emit constructors first, in the hope that we don't need to use all
the constructor functions in favour of just building tuples immediately.
-}

generateErl :: [(Name,DDecl)] -> [ExportIFace] -> ErlCG ()
generateErl alldecls exportifaces =
  let (ctors, funs) = (isCtor . snd) `partition` alldecls
  in do generateMain (sMN 0 "runMain")
        mapM_ (\(_,DConstructor name _ arity) -> generateCtor name arity) ctors
        mapM_ (\(_,DFun name args exp)        -> generateFun name args exp) funs
        mapM_ (\(Export name file exports)    -> generateExportIFace name file exports) exportifaces
  where isCtor (DFun _ _ _) = False
        isCtor (DConstructor _ _ _) = True



generateMain :: Name -> ErlCG ()
generateMain m = do erlExp <- inScope . generateExp $ DApp False m []
                    emitForm ("main", 1) ("main(_Args) -> " ++ erlExp ++ ".")
                    wipeScope

generateFun :: Name -> [Name] -> DExp -> ErlCG ()
generateFun _ _ DNothing = return ()
generateFun name args exp = do erlExp <- inScopeWithVars args' $ generateExp exp
                               emitForm (erlAtom name, length args) ((erlAtom name) ++ "(" ++ argsStr ++ ") -> "++ erlExp ++".")
                               wipeScope
  where args' = map erlVar args
        argsStr = ", " `intercalate` args'

generateCtor :: Name -> Int -> ErlCG ()
generateCtor name arity = addRecord name arity

generateExportIFace :: Name -> String -> [Export] -> ErlCG ()
generateExportIFace _ _ exports = mapM_ generateExport exports

-- TODO: Finish this
generateExport :: Export -> ErlCG ()
generateExport (ExportData _) = return ()
generateExport (ExportFun _ _ _ _) = return () -- TODO: Generate Something

generateExp :: DExp -> ErlCG String
generateExp (DV lv)            = getVar lv

generateExp (DApp _ name exprs)  = do res <- isRecord name (length exprs)
                                      exprs' <- mapM generateExp exprs
                                      if res
                                        then specialCaseCtor name exprs'
                                        else return $ erlCall (erlAtom name) exprs'

generateExp (DLet vn exp inExp) = do exp' <- generateExp exp
                                     inExp' <- generateExp inExp
                                     -- We should really be adding a local here, I think
                                     return $ (erlVar vn) ++ " = begin " ++ exp' ++ "end, "++ inExp'

-- These are never generated by the compiler right now
generateExp (DUpdate _ exp) = generateExp exp

-- The tuple is 1-indexed, and its first field is the name of the
-- constructor, which is why we have to add 2 to the index we're given
-- in order to do the correct lookup.
generateExp (DProj exp n)      = do exp' <- generateExp exp
                                    return $ erlCall "element" [show (n+2), exp']


generateExp (DC _ _ name exprs) = do res <- isRecord name (length exprs)
                                     exprs' <- mapM generateExp exprs
                                     if res
                                       then specialCaseCtor name exprs'
                                       else throwError $ "Constructor not found: " ++ show name ++ " with " ++ show (length exprs) ++ "arguments"

generateExp (DCase _  exp alts) = generateCase exp alts
generateExp (DChkCase exp alts) = generateCase exp alts

generateExp (DConst c)          = generateConst c

generateExp (DOp op exprs)      = do exprs' <- mapM generateExp exprs
                                     generatePrim op exprs'

generateExp DNothing            = return "undefined"
generateExp (DError str)        = return ("erlang:error("++ show str ++")")

generateExp (DForeign ret nm args) = generateForeign ret nm args

-- Case Statements
generateCase :: DExp -> [DAlt] -> ErlCG String
generateCase expr alts = do expr' <- generateExp expr
                            alts' <- mapM generateCaseAlt alts
                            return $ "case " ++ expr' ++ " of\n" ++ (";\n" `intercalate` alts') ++ "\nend"

-- Case Statement Clauses
generateCaseAlt :: DAlt -> ErlCG String
generateCaseAlt (DConCase _ name args expr) = do res <- isRecord name (length args)
                                                 let args' = map erlVar args
                                                 if res
                                                   then do expr' <- inScopeWithVars args' $ generateExp expr
                                                           ctor <- specialCaseCtor name args'
                                                           return $ ctor ++ " -> " ++ expr'
                                                   else throwError "No Constructor to Match With"
generateCaseAlt (DConstCase con expr)       = do con' <- generateConst con
                                                 expr' <- inScope $ generateExp expr
                                                 return $ con' ++ " -> " ++ expr'
generateCaseAlt (DDefaultCase expr)         = do expr' <- inScope $ generateExp expr
                                                 return $ "_ -> " ++ expr'


-- Foreign Calls
generateForeign :: FDesc -> FDesc -> [(FDesc,DExp)] -> ErlCG String
generateForeign _ (FStr "list_to_atom") [(_,DConst (Str s))] = return $ strAtom s
generateForeign ret (FStr nm) args = do args' <- mapM (generateExp . snd) args
                                        return $ nm ++ "("++ (", " `intercalate` args') ++")"

-- Some Notes on Constants
--
-- - All Erlang's numbers are arbitrary precision. The VM copes with
-- what size they really are underneath, including whether they're a
-- float.
--
-- - Characters are just numbers. However, there's also a nice syntax
-- for them, which is $<char> is the number of that character. So, if
-- the char is printable, it's best to use the $<char> notation than
-- the number.
--
-- - Strings are actually lists of numbers. However the nicer syntax
-- is within double quotes. Some things will fail, but it's just
-- easier to assume all strings are full of printables, if they're
-- constant.
generateConst :: Const -> ErlCG String
generateConst c | constIsType c = return $ strAtom (show c)
generateConst (I i)   = return $ show i
generateConst (BI i)  = return $ show i
generateConst (B8 w)  = return $ show w
generateConst (B16 w) = return $ show w
generateConst (B32 w) = return $ show w
generateConst (B64 w) = return $ show w
generateConst (Fl f)  = return $ show f
                     -- Accurate Enough for now
generateConst (Ch c) | c == '\\'  = return "$\\\\"
                     | isPrint c = return ['$',c]
                     | otherwise = return $ show (fromEnum c)
                      -- Accurate Enough for Now
generateConst (Str s) | any (== '\\') s = do chars <- sequence $ map (generateConst . Ch) s
                                             return $ "[" ++ (", " `intercalate` chars) ++ "]"
                      | all isPrint s = return $ show s
                      | otherwise = do chars <- sequence $ map (generateConst . Ch) s
                                       return $ "[" ++ (", " `intercalate` chars) ++ "]"

generateConst c = throwError $ "Unknown Constant " ++ show c

-- Some Notes on Primitive Operations
--
-- - Official Docs:
-- http://www.erlang.org/doc/reference_manual/expressions.html#id78907
-- http://www.erlang.org/doc/reference_manual/expressions.html#id78646
--
-- - Oh look, because we only have one number type, all mathematical
-- operations are really easy. The only thing to note is this: `div`
-- is explicitly integer-only, so is worth using whenever integer
-- division is asked for (to avoid everything becoming floaty). '/' is
-- for any number, so we just use that on floats.
--
--
generatePrim :: PrimFn -> [String] -> ErlCG String
generatePrim (LPlus _)       [x,y] = return $ erlBinOp "+" x y
generatePrim (LMinus _)      [x,y] = return $ erlBinOp "-" x y
generatePrim (LTimes _)      [x,y] = return $ erlBinOp "*" x y
generatePrim (LUDiv _)       [x,y] = return $ erlBinOp "div" x y
generatePrim (LSDiv ATFloat) [x,y] = return $ erlBinOp "/" x y
generatePrim (LSDiv _)       [x,y] = return $ erlBinOp "div" x y
generatePrim (LURem _)       [x,y] = return $ erlBinOp "rem" x y
generatePrim (LSRem _)       [x,y] = return $ erlBinOp "rem" x y
generatePrim (LAnd _)        [x,y] = return $ erlBinOp "band" x y
generatePrim (LOr _)         [x,y] = return $ erlBinOp "bor" x y
generatePrim (LXOr _)        [x,y] = return $ erlBinOp "bxor" x y
generatePrim (LCompl _)      [x]   = return $ erlBinOp "bnot" "" x  -- hax
generatePrim (LSHL _)        [x,y] = return $ erlBinOp "bsl" x y
generatePrim (LASHR _)       [x,y] = return $ erlBinOp "bsr" x y
generatePrim (LLSHR _)       [x,y] = return $ erlBinOp "bsr" x y -- using an arithmetic shift when we should use a logical one.
generatePrim (LEq _)         [x,y] = return $ erlBoolOp "=:=" x y
generatePrim (LLt _)         [x,y] = return $ erlBoolOp "<" x y
generatePrim (LLe _)         [x,y] = return $ erlBoolOp "=<" x y
generatePrim (LGt _)         [x,y] = return $ erlBoolOp ">" x y
generatePrim (LGe _)         [x,y] = return $ erlBoolOp ">=" x y
generatePrim (LSLt _)        [x,y] = return $ erlBoolOp "<" x y
generatePrim (LSLe _)        [x,y] = return $ erlBoolOp "=<" x y
generatePrim (LSGt _)        [x,y] = return $ erlBoolOp ">" x y
generatePrim (LSGe _)        [x,y] = return $ erlBoolOp ">=" x y
generatePrim (LSExt _ _)     [x]   = return $ x -- Not sure if correct
generatePrim (LZExt _ _)     [x]   = return $ x -- Not sure if correct
generatePrim (LTrunc _ _)    [x]   = return $ x -- Not sure if correct

generatePrim (LIntFloat _)   [x]   = return $ erlBinOp "+" x "0.0"
generatePrim (LFloatInt _)   [x]   = return $ erlCall "trunc" [x]
generatePrim (LIntStr _)     [x]   = return $ erlCall "integer_to_list" [x]
generatePrim (LStrInt _)     [x]   = return $ erlCall "list_to_integer" [x]
generatePrim (LFloatStr)     [x]   = return $ erlCall "float_to_list" [x, "[compact, {decimals, 20}]"]
generatePrim (LStrFloat)     [x]   = return $ erlCall "list_to_float" [x]
generatePrim (LChInt _)      [x]   = return $ x -- Chars are just Integers anyway.
generatePrim (LIntCh _)      [x]   = return $ x
generatePrim (LBitCast _ _)  [x]   = return $ x

generatePrim (LFExp)         [x]   = return $ erlCallMFA "math" "exp" [x]
generatePrim (LFLog)         [x]   = return $ erlCallMFA "math" "log" [x]
generatePrim (LFSin)         [x]   = return $ erlCallMFA "math" "sin" [x]
generatePrim (LFCos)         [x]   = return $ erlCallMFA "math" "cos" [x]
generatePrim (LFTan)         [x]   = return $ erlCallMFA "math" "tan" [x]
generatePrim (LFASin)        [x]   = return $ erlCallMFA "math" "asin" [x]
generatePrim (LFACos)        [x]   = return $ erlCallMFA "math" "acos" [x]
generatePrim (LFATan)        [x]   = return $ erlCallMFA "math" "atan" [x]
generatePrim (LFSqrt)        [x]   = return $ erlCallMFA "math" "sqrt" [x]
generatePrim (LFFloor)       [x]   = return $ erlCallIRTS "ceil" [x]
generatePrim (LFCeil)        [x]   = return $ erlCallIRTS "floor" [x]
generatePrim (LFNegate)      [x]   = return $ "-" ++ x

generatePrim (LStrHead)      [x]   = return $ erlCall "hd" [x]
generatePrim (LStrTail)      [x]   = return $ erlCall "tl" [x]
generatePrim (LStrCons)      [x,y] = return $ "["++x++"|"++y++"]"
generatePrim (LStrIndex)     [x,y] = return $ erlCallIRTS "str_index" [x,y]
generatePrim (LStrRev)       [x]   = return $ erlCallMFA "lists" "reverse" [x]
generatePrim (LStrConcat)    [x,y] = return $ erlBinOp "++" x y
generatePrim (LStrLt)        [x,y] = return $ erlBoolOp "<" x y
generatePrim (LStrEq)        [x,y] = return $ erlBoolOp "=:=" x y
generatePrim (LStrLen)       [x]   = return $ erlCall "length" [x]

generatePrim (LReadStr)      [_]     = return $ erlCallIRTS "read_str" []
generatePrim (LWriteStr)     [_,s]   = return $ erlCallIRTS "write_str" [s]

generatePrim (LSystemInfo)    _    = throwError "System Info not supported" -- TODO

generatePrim (LFork)         [e]   = return $ "spawn(fun() -> 'EVAL0'("++ e ++") end)"
generatePrim (LPar)          [e]   = return e

generatePrim (LExternal nm)  args  = generateExternalPrim nm args

generatePrim p a = do liftIO . putStrLn $ "No Primitive: " ++ show p ++ " on " ++ show (length a) ++ " args."
                      throwError "generatePrim: Unknown Op, or incorrect arity"


generateExternalPrim :: Name -> [String] -> ErlCG String
generateExternalPrim nm _ | nm == sUN "prim__stdin"  = return $ "standard_io"
                          | nm == sUN "prim__stdout" = return $ "standard_io"
                          | nm == sUN "prim__stderr" = return $ "standard_io"
                          | nm == sUN "prim__vm"     = return $ "undefined"
                          | nm == sUN "prim__null"   = return $ "undefined"
generateExternalPrim nm [_,h]   | nm == sUN "prim__readFile"  = return $ erlCallIRTS "read_file" [h]
generateExternalPrim nm [_,h,s] | nm == sUN "prim__writeFile" = return $ erlCallIRTS "write_file" [h,s]
generateExternalPrim nm [p,l] | nm == sUN "prim__registerPtr" = return $ erlCallIRTS "register_ptr" [p,l]
generateExternalPrim nm args = do liftIO . putStrLn $ "Unknown External Primitive: " ++ show nm ++ " on " ++ show (length args) ++ "args."
                                  throwError "generatePrim: Unknown External Primitive"



erlBinOp :: String -> String -> String -> String
erlBinOp op a b = concat ["(",a," ",op," ",b,")"]

-- Erlang Atoms can contain quite a lot of chars, so let's see how they cope
erlAtom :: Name -> String
erlAtom n = strAtom (showCG n)

strAtom :: String -> String
strAtom s = "\'" ++ concatMap atomchar s ++ "\'"
  where atomchar x | x == '\'' = "\\'"
                   | x == '\\' = "\\\\"
                   | x == '.' = "_"
                   | x `elem` "{}" = ""
                   | isPrint x = [x]
                   | otherwise = "_" ++ show (fromEnum x) ++ "_"


-- Erlang Variables have a more restricted set of chars, and must
-- start with a capital letter (erased can start with an underscore)
erlVar :: Name -> String
erlVar NErased = "_Erased"
erlVar n = capitalize (concatMap varchar (showCG n))
  where varchar x | isAlpha x = [x]
                  | isDigit x = [x]
                  | x == '_'  = "_"
                  | x `elem` "{}" = "" -- I hate the {}, and they fuck up everything.
                  | otherwise = "_" ++ show (fromEnum x) ++ "_"
        capitalize [] = []
        capitalize (x:xs) | isUpper x = x:xs
                          | isLower x = (toUpper x):xs
                          | otherwise = 'V':x:xs

erlTuple :: [String] -> String
erlTuple elems = "{" ++ (", " `intercalate` elems) ++ "}"

erlCall :: String -> [String] -> String
erlCall fun args = fun ++ "("++ (", " `intercalate` args) ++")"

erlCallMFA :: String -> String -> [String] -> String
erlCallMFA mod fun args = mod ++ ":" ++ erlCall fun args

erlCallIRTS :: String -> [String] -> String
erlCallIRTS f a = erlCallMFA "idris_erlang_rts" f a

erlBoolOp :: String -> String -> String -> String
erlBoolOp op x y = erlCallIRTS "bool_cast" [erlBinOp op x y]


-- This is where we special case various constructors.
--
-- * Prelude.List.Nil gets turned into []
-- * Prelude.List.(::) gets turned into [head|tail]
-- * MkUnit () gets turned into {}
-- * Builtins.MkPair gets turned into {a,b}
-- * Prelude.Bool.True gets turned into true
-- * Prelude.Bool.False gets turned into false
-- * Zero Argument constructors become single atoms
--
specialCaseCtor :: Name -> [String] -> ErlCG String
specialCaseCtor nm args | nm == (sNS (sUN "Nil") ["List", "Prelude"]) = return "[]"
                        | nm == (sNS (sUN "::") ["List", "Prelude"])  = let [hd,tl] = args
                                                                        in return $ "["++ hd ++ "|" ++ tl ++"]"
                        | nm == (sUN "MkUnit") = return "{}"
                        | nm == (sNS (sUN "MkPair") ["Builtins"]) = let [a,b] = args
                                                                    in return $ "{"++ a ++ ", " ++ b ++"}"
                        | nm == (sNS (sUN "True") ["Bool", "Prelude"])  = return "true"
                        | nm == (sNS (sUN "False") ["Bool", "Prelude"]) = return "false"

specialCaseCtor nm []   = return $ erlAtom nm
specialCaseCtor nm args = return $ "{"++ (", " `intercalate` (erlAtom nm : args)) ++"}"
