-----------------------------------------------------------------------------
-- Module      :  Lexer.x
-- Copyright   : (c) [1999..2004] Manuel M T Chakravarty
--               (c) 2005 Duncan Coutts
--               (c) 2008 Benedikt Huber
-- License     :  BSD-style
-- Maintainer  :  benedikt.huber@gmail.com
-- Portability :  portable
--
--  Lexer for C files, after being processed by the C preprocessor
--
--  We assume that the input already went through cpp.  Thus, we do not handle
--  comments and preprocessor directives here.  It supports the
--  C99 `restrict' extension: <http://www.lysator.liu.se/c/restrict.html> as
--  well as inline functions.
--
--  Comments:
--
--  * Universal character names and multi-character character constants,
--    as well as trigraphs are unsupported. They are lexed, but yield an error.
--
--  * We add `typedef-name' (K&R 8.9) as a token, as proposed in K&R A13.
--    However, as these tokens cannot be recognized lexically, but require a
--    context analysis, they are never produced by the lexer, but instead have
--    to be introduced in a later phase (by converting the corresponding
--    identifiers).
--
--  * We also recognize GNU C `__attribute__', `__extension__', `__complex__',
--    `__const',  `__const__', `__imag', `__imag__', `__inline', `__inline__',
--    `__real', `__real__, `__restrict', and `__restrict__'.
--
--  * Any line starting with `#pragma' is ignored.
--
--  With K&R we refer to ``The C Programming Language'', second edition, Brain
--  W. Kernighan and Dennis M. Ritchie, Prentice Hall, 1988.
--
--  With C99 we refer to ``ISO/IEC 9899:TC3'',
--  available online at http://www.open-std.org/JTC1/SC22/WG14/www/docs/n1256.pdf.
--
--- TODO ----------------------------------------------------------------------
--
--  * There are more GNU C specific keywords.  Add them and change `Parser.y'
--    correspondingly (in particular, most tokens within __attribute ((...))
--    expressions are actually keywords, but we handle them as identifiers at
--    the moment).
--
--  * Add support for bytestrings

{

module Language.C.Parser.Lexer (lexC, parseError) where

import Data.Char (chr, isDigit)
import Data.List (uncons)
import Data.Word (Word8)
import Control.Monad (liftM, when)

import Language.C.Data.InputStream
  (InputStream, inputStreamEmpty, takeByte, takeChar, takeChars)

-- (    InputStream, readInputStream,inputStreamToString,inputStreamFromString,
--     takeByte, takeChar, inputStreamEmpty, takeChars,
--     countLines,
-- )
import Language.C.Data.Position
import Language.C.Data.Ident    (mkIdent)

import Language.C.Syntax.Constants

import Language.C.Parser.Tokens
import Language.C.Parser.ParserMonad
}

$space = [ \ \t ]                           -- horizontal white space
$eol   = \n                                 -- end of line

$letter   = [a-zA-Z]
$identletter = [a-zA-Z_\$]                  -- GNU extension: allow $ in variable names
$octdigit = 0-7
$digit    = 0-9
$digitNZ  = 1-9
$hexdigit = [0-9a-fA-F]

$inchar   = . # [ \\ \' \n \r ]       -- valid character in char constant
$instr    = . # [ \\ \" \n \r ]       -- valid character in a string literal
$infname  = . # [ \\ \" ]             -- valid character in a filename

@sp  = $space*

-- character escape sequence (follows K&R A2.5.2)
--
-- * also used for strings
-- * C99: 6.4.4.4
@charesc  = \\([ntvbrfaeE\\\?\'\"]|$octdigit{1,3}|x$hexdigit+)
@ucn      = \\u$hexdigit{4}|\\U$hexdigit{8}

-- components of integer constants
--
-- * C99: 6.4.4.1
@int = $digitNZ$digit*

-- integer suffixes
@llsuffix  = ll|LL
@gnusuffix = [ij]?
@intsuffix = [uU][lL]?|[uU]@llsuffix|[lL][uU]?|@llsuffix[uU]?
@intgnusuffix = @intsuffix@gnusuffix?|@gnusuffix@intsuffix?

-- components of float constants (follows K&R A2.5.3)
--
-- * C99: 6.4.4.2
@digits    = $digit+
@intpart   = @digits
@fractpart = @digits

@mantpart  = @intpart?\.@fractpart|@intpart\.
@exppart   = [eE][\+\-]?@digits

@hexprefix = 0x
@hexdigits = $hexdigit+
@hexmant   = @hexdigits?\.@hexdigits|@hexdigits\.
@binexp    = [pP][\+\-]?@digits

-- Suffixes `qQwW` are GNU floating type extensions: <https://gcc.gnu.org/onlinedocs/gcc/Floating-Types.html>
@iec60559suffix = (16|32|64|128)[x]?
@floatsuffix    = [fFlLqQwW]@iec60559suffix?
@floatgnusuffix = @floatsuffix@gnusuffix?|@gnusuffix@floatsuffix?

-- clang version literals with a major.minor.rev
@clangversion = @intpart\.@intpart\.@intpart

tokens :-

-- whitespace (follows K&R A2.1)
--
-- * horizontal and vertical tabs, newlines, and form feeds are filter out by
--   `Lexers.ctrlLexer'
--
-- * comments are not handled, as we assume the input already went through cpp
--
$white+         ;

-- #line directive (C11 6.10.4, GCC Line Control)
--
-- * standard form: int => change line number
-- * standard form: int string => change source file and line number
-- * preprocessor (gcc/clang): int string int => change source file and line number,
--       push or pop item from stack
--
-- * see https://gcc.gnu.org/onlinedocs/cpp/Preprocessor-Output.html
--
\#$space*@digits$space*(\"($infname|@charesc)*\"$space*)?(@int$space*)*\r?$eol
  { \pos len str -> setPos (adjustLineDirective len (takeChars len str) pos) >> lexToken' False }

-- #pragma directive (K&R A12.8)
--
-- * we simply ignore any #pragma (but take care to update the position
--   information)
--
\#$space*pragma.*$eol   ;

-- #ident directive, eg used by rcs/cvs
--
-- * we simply ignore any #ident (but take care to update the position
--   information)
--
\#$space*ident.*$eol    ;

-- identifiers and keywords (follows K&R A2.3 and A2.4)
--
$identletter($identletter|$digit)*  { \pos len str -> idkwtok (takeChars len str) pos }

-- constants (follows K&R A2.5)
--
-- * K&R,C99 explicitly mention `enumeration-constants'; however, as they are
--   lexically identifiers, we do not have an extra case for them
--

-- integer constants (follows K&R A2.5.1, C99 6.4.4.1)
-- NOTE: 0 is lexed as octal integer constant, and readCOctal takes care of this
0$octdigit*@intgnusuffix?       { token_plus CTokILit readCOctal }
$digitNZ$digit*@intgnusuffix?   { token_plus CTokILit (readCInteger DecRepr) }
0[xX]$hexdigit+@intgnusuffix?   { token_plus CTokILit (readCInteger HexRepr . drop 2) }

(0$octdigit*|$digitNZ$digit*|0[xX]$hexdigit+)[uUlL]+ { token_fail "Invalid integer constant suffix" }

-- character constants (follows K&R A2.5.2, C99 6.4.4.4)
--
-- * Universal Character Names are unsupported and cause an error.
\'($inchar|@charesc)\'  { token CTokCLit (cChar . fst . unescapeChar . drop 1) }
L\'($inchar|@charesc)\' { token CTokCLit (cChar_w . fst . unescapeChar . drop 2) }
\'($inchar|@charesc){2,}\' { token CTokCLit (flip cChars False . unescapeMultiChars . drop 1) }
L\'($inchar|@charesc){2,}\' { token CTokCLit (flip cChars True . unescapeMultiChars . drop 2) }

-- Clang version literals
@clangversion           { token (\pos -> CTokClangC pos . ClangCVersionTok) readClangCVersion }

-- float constants (follows K&R A2.5.3. C99 6.4.4.2)
--
-- * NOTE: Hexadecimal floating constants without binary exponents are forbidden.
--         They generate a lexer error, because they are hard to recognize in the parser.
(@mantpart@exppart?|@intpart@exppart)@floatgnusuffix?  { token CTokFLit readCFloat }
@hexprefix(@hexmant|@hexdigits)@binexp@floatgnusuffix? { token CTokFLit readCFloat }
@hexprefix@hexmant                                     { token_fail "Hexadecimal floating constant requires an exponent" }

-- string literal (follows K&R A2.6)
-- C99: 6.4.5.
\"($instr|@charesc)*\"      { token CTokSLit (cString . unescapeString . init . drop 1) }
L\"($instr|@charesc)*\"     { token CTokSLit (cString_w . unescapeString . init . drop 2) }

L?\'@ucn\'                        { token_fail "Universal character names are unsupported" }
L?\'\\[^0-7'\"\?\\abfnrtvuUx]\'     { token_fail "Invalid escape sequence" }
L?\"($inchar|@charesc)*@ucn($inchar|@charesc|@ucn)*\" { token_fail "Universal character names in string literals are unsupported"}

-- operators and separators
--
"("   { token_ 1 CTokLParen }
")"   { token_ 1 CTokRParen  }
"["   { token_ 1 CTokLBracket }
"]"   { token_ 1 CTokRBracket }
"->"  { token_ 2 CTokArrow }
"."   { token_ 1 CTokDot }
"!"   { token_ 1 CTokExclam }
"~"   { token_ 1 CTokTilde }
"++"  { token_ 2 CTokInc }
"--"  { token_ 2 CTokDec }
"+"   { token_ 1 CTokPlus }
"-"   { token_ 1 CTokMinus }
"*"   { token_ 1 CTokStar }
"/"   { token_ 1 CTokSlash }
"%"   { token_ 1 CTokPercent }
"&"   { token_ 1 CTokAmper }
"<<"  { token_ 2 CTokShiftL }
">>"  { token_ 2 CTokShiftR }
"<"   { token_ 1 CTokLess }
"<="  { token_ 2 CTokLessEq }
">"   { token_ 1 CTokHigh }
">="  { token_ 2 CTokHighEq }
"=="  { token_ 2 CTokEqual }
"!="  { token_ 2 CTokUnequal }
"^"   { token_ 1 CTokHat }
"|"   { token_ 1 CTokBar }
"&&"  { token_ 2 CTokAnd }
"||"  { token_ 2 CTokOr }
"?"   { token_ 1 CTokQuest }
":"   { token_ 1 CTokColon }
"="   { token_ 1 CTokAssign }
"+="  { token_ 2 CTokPlusAss }
"-="  { token_ 2 CTokMinusAss }
"*="  { token_ 2 CTokStarAss }
"/="  { token_ 2 CTokSlashAss }
"%="  { token_ 2 CTokPercAss }
"&="  { token_ 2 CTokAmpAss }
"^="  { token_ 2 CTokHatAss }
"|="  { token_ 2 CTokBarAss }
"<<=" { token_ 3 CTokSLAss }
">>=" { token_ 3 CTokSRAss }
","   { token_ 1 CTokComma }
\;    { token_ 1 CTokSemic }
"{"   { token_ 1 CTokLBrace }
"}"   { token_ 1 CTokRBrace }
"..." { token_ 3 CTokEllipsis }


{
-- Fix the 'octal' lexing of '0'
readCOctal :: String -> Either String CInteger
readCOctal s@('0':r) =
    case r of
        (c:_) | isDigit c -> readCInteger OctalRepr r
        _                 -> readCInteger DecRepr s
readCOctal _ = error "ReadOctal: string does not start with `0'"


-- We use the odd looking list of string patterns here rather than normal
-- string literals since GHC converts the latter into a sequence of string
-- comparisons (ie a linear search) but it translates the former using its
-- effecient pattern matching which gives us the expected radix-style search.
-- This change makes a significant performance difference [chak]
--
-- To make this a little more maintainable, we autogenerate it from this list,
-- using the script GenerateKeywords.hs (in /scripts)
{-
alignas _Alignas,
alignof _Alignof __alignof alignof __alignof__,
asm @__,
atomic _Atomic,
auto, break, bool _Bool,
case, char, const @__, continue,
complex _Complex __complex__
default, do, double,
else, enum, extern,
float, for,
generic _Generic,
goto,
if, inline @__, int,
__int128 __int128_t,
long,
noreturn _Noreturn,
nullable _Nullable __nullable,
nonnull _Nonnull __nonnull,
register, restrict @__, return
short, signed @__, sizeof, static,
staticAssert _Static_assert,
struct, switch,
typedef, typeof @__,
thread __thread _Thread_local
(CTokUInt128) __uint128 __uint128_t,
union,
unsigned,
void,
volatile @__,
while,
label __label__
BFloat16 __bf16
(CTokFloatN 16 False) __fp16
(CTokFloatN 16 False) _Float16
(CTokFloatN 16 True) _Float16x
(CTokFloatN 32 False) _Float32
(CTokFloatN 32 True) _Float32x
(CTokFloatN 64 False) _Float64
(CTokFloatN 64 True) _Float64x
(CTokFloatN 128 False) _Float128 __float128
(CTokFloatN 128 True) _Float128x
(CTokGnuC GnuCAttrTok) __attribute __attribute__
(CTokGnuC GnuCExtTok) __extension__
(CTokGnuC GnuCComplexReal) __real __real__
(CTokGnuC GnuCComplexImag) __imag __imag__
(CTokGnuC GnuCVaArg) __builtin_va_arg
(CTokGnuC GnuCOffsetof) __builtin_offsetof
(CTokGnuC GnuCTyCompat) __builtin_types_compatible_p
(CTokGnuC GnuBitCast) __builtin_bit_cast
(flip CTokClangC ClangBuiltinConvertVector) __builtin_convertvector
-}

-- Tokens: _Alignas _Alignof __alignof alignof __alignof__ __asm asm __asm__ _Atomic auto break _Bool case char __const const __const__ continue _Complex __complex__ default do double else enum extern float for _Generic goto if __inline inline __inline__ int __int128_t long _Noreturn _Nullable __nullable _Nonnull __nonnull register __restrict restrict __restrict__ return short __signed signed __signed__ sizeof static _Static_assert struct switch typedef __typeof typeof __typeof__ __thread _Thread_local __uint128 __uint128_t union unsigned void __volatile volatile __volatile__ while __label__ __bf16 __fp16 _Float16 _Float16x _Float32 _Float32x _Float64 _Float64x _Float128 __float128 _Float128x __attribute __attribute__ __extension__ __real __real__ __imag __imag__ __builtin_va_arg __builtin_offsetof __builtin_types_compatible_p __builtin_bit_cast __builtin_convertvector
idkwtok ('_' : 'A' : 'l' : 'i' : 'g' : 'n' : 'a' : 's' : []) = tok 8 CTokAlignas
idkwtok ('_' : 'A' : 'l' : 'i' : 'g' : 'n' : 'o' : 'f' : []) = tok 8 CTokAlignof
idkwtok ('_' : 'A' : 't' : 'o' : 'm' : 'i' : 'c' : []) = tok 7 CTokAtomic
idkwtok ('_' : 'B' : 'o' : 'o' : 'l' : []) = tok 5 CTokBool
idkwtok ('_' : 'C' : 'o' : 'm' : 'p' : 'l' : 'e' : 'x' : []) = tok 8 CTokComplex
idkwtok ('_' : '_' : 'b' : 'f' : '1' : '6' : []) = tok 6 CTokBFloat16
idkwtok ('_' : '_' : 'f' : 'p' : '1' : '6' : []) = tok 6 (CTokFloatN 16 False)
#ifdef IEC_60559_TYPES_EXT
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '1' : '6' : []) = tok 8 (CTokFloatN 16 False)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '1' : '6' : 'x' : []) = tok 9 (CTokFloatN 16 True)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '1' : '2' : '8' : []) = tok 9 (CTokFloatN 128 False)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '1' : '2' : '8' : 'x' : []) = tok 10 (CTokFloatN 128 True)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '3' : '2' : []) = tok 8 (CTokFloatN 32 False)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '3' : '2' : 'x' : []) = tok 9 (CTokFloatN 32 True)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '6' : '4' : []) = tok 8 (CTokFloatN 64 False)
idkwtok ('_' : 'F' : 'l' : 'o' : 'a' : 't' : '6' : '4' : 'x' : []) = tok 9 (CTokFloatN 64 True)
#endif
idkwtok ('_' : 'G' : 'e' : 'n' : 'e' : 'r' : 'i' : 'c' : []) = tok 8 CTokGeneric
idkwtok ('_' : 'N' : 'o' : 'n' : 'n' : 'u' : 'l' : 'l' : []) = tok 8 CTokNonnull
idkwtok ('_' : 'N' : 'o' : 'r' : 'e' : 't' : 'u' : 'r' : 'n' : []) = tok 9 CTokNoreturn
idkwtok ('_' : 'N' : 'u' : 'l' : 'l' : 'a' : 'b' : 'l' : 'e' : []) = tok 9 CTokNullable
idkwtok ('_' : 'S' : 't' : 'a' : 't' : 'i' : 'c' : '_' : 'a' : 's' : 's' : 'e' : 'r' : 't' : []) = tok 14 CTokStaticAssert
idkwtok ('_' : 'T' : 'h' : 'r' : 'e' : 'a' : 'd' : '_' : 'l' : 'o' : 'c' : 'a' : 'l' : []) = tok 13 CTokThread
idkwtok ('_' : '_' : 'a' : 'l' : 'i' : 'g' : 'n' : 'o' : 'f' : []) = tok 9 CTokAlignof
idkwtok ('a' : 'l' : 'i' : 'g' : 'n' : 'o' : 'f' : []) = tok 7 CTokAlignof
idkwtok ('_' : '_' : 'a' : 'l' : 'i' : 'g' : 'n' : 'o' : 'f' : '_' : '_' : []) = tok 11 CTokAlignof
idkwtok ('_' : '_' : 'a' : 's' : 'm' : []) = tok 5 CTokAsm
idkwtok ('a' : 's' : 'm' : []) = tok 3 CTokAsm
idkwtok ('_' : '_' : 'a' : 's' : 'm' : '_' : '_' : []) = tok 7 CTokAsm
idkwtok ('_' : '_' : 'a' : 't' : 't' : 'r' : 'i' : 'b' : 'u' : 't' : 'e' : []) = tok 11 (CTokGnuC GnuCAttrTok)
idkwtok ('_' : '_' : 'a' : 't' : 't' : 'r' : 'i' : 'b' : 'u' : 't' : 'e' : '_' : '_' : []) = tok 13 (CTokGnuC GnuCAttrTok)
idkwtok ('a' : 'u' : 't' : 'o' : []) = tok 4 CTokAuto
idkwtok ('b' : 'r' : 'e' : 'a' : 'k' : []) = tok 5 CTokBreak
idkwtok ('_' : '_' : 'b' : 'u' : 'i' : 'l' : 't' : 'i' : 'n' : '_' : 'b' : 'i' : 't' : '_' : 'c' : 'a' : 's' : 't' : []) = tok 18 (flip CTokClangC ClangCBitCast)
idkwtok ('_' : '_' : 'b' : 'u' : 'i' : 'l' : 't' : 'i' : 'n' : '_' : 'c' : 'o' : 'n' : 'v' : 'e' : 'r' : 't' : 'v' : 'e' : 'c' : 't' : 'o' : 'r' : []) = tok 23 (flip CTokClangC ClangBuiltinConvertVector)
idkwtok ('_' : '_' : 'b' : 'u' : 'i' : 'l' : 't' : 'i' : 'n' : '_' : 'o' : 'f' : 'f' : 's' : 'e' : 't' : 'o' : 'f' : []) = tok 18 (CTokGnuC GnuCOffsetof)
idkwtok ('_' : '_' : 'b' : 'u' : 'i' : 'l' : 't' : 'i' : 'n' : '_' : 't' : 'y' : 'p' : 'e' : 's' : '_' : 'c' : 'o' : 'm' : 'p' : 'a' : 't' : 'i' : 'b' : 'l' : 'e' : '_' : 'p' : []) = tok 28 (CTokGnuC GnuCTyCompat)
idkwtok ('_' : '_' : 'b' : 'u' : 'i' : 'l' : 't' : 'i' : 'n' : '_' : 'v' : 'a' : '_' : 'a' : 'r' : 'g' : []) = tok 16 (CTokGnuC GnuCVaArg)
idkwtok ('c' : 'a' : 's' : 'e' : []) = tok 4 CTokCase
idkwtok ('c' : 'h' : 'a' : 'r' : []) = tok 4 CTokChar
idkwtok ('_' : '_' : 'c' : 'o' : 'm' : 'p' : 'l' : 'e' : 'x' : '_' : '_' : []) = tok 11 CTokComplex
idkwtok ('_' : '_' : 'c' : 'o' : 'n' : 's' : 't' : []) = tok 7 CTokConst
idkwtok ('c' : 'o' : 'n' : 's' : 't' : []) = tok 5 CTokConst
idkwtok ('_' : '_' : 'c' : 'o' : 'n' : 's' : 't' : '_' : '_' : []) = tok 9 CTokConst
idkwtok ('c' : 'o' : 'n' : 't' : 'i' : 'n' : 'u' : 'e' : []) = tok 8 CTokContinue
idkwtok ('d' : 'e' : 'f' : 'a' : 'u' : 'l' : 't' : []) = tok 7 CTokDefault
idkwtok ('d' : 'o' : []) = tok 2 CTokDo
idkwtok ('d' : 'o' : 'u' : 'b' : 'l' : 'e' : []) = tok 6 CTokDouble
idkwtok ('e' : 'l' : 's' : 'e' : []) = tok 4 CTokElse
idkwtok ('e' : 'n' : 'u' : 'm' : []) = tok 4 CTokEnum
idkwtok ('_' : '_' : 'e' : 'x' : 't' : 'e' : 'n' : 's' : 'i' : 'o' : 'n' : '_' : '_' : []) = tok 13 (CTokGnuC GnuCExtTok)
idkwtok ('e' : 'x' : 't' : 'e' : 'r' : 'n' : []) = tok 6 CTokExtern
idkwtok ('f' : 'l' : 'o' : 'a' : 't' : []) = tok 5 CTokFloat
idkwtok ('_' : '_' : 'f' : 'l' : 'o' : 'a' : 't' : '1' : '2' : '8' : []) = tok 10 (CTokFloatN 128 False)
idkwtok ('f' : 'o' : 'r' : []) = tok 3 CTokFor
idkwtok ('g' : 'o' : 't' : 'o' : []) = tok 4 CTokGoto
idkwtok ('i' : 'f' : []) = tok 2 CTokIf
idkwtok ('_' : '_' : 'i' : 'm' : 'a' : 'g' : []) = tok 6 (CTokGnuC GnuCComplexImag)
idkwtok ('_' : '_' : 'i' : 'm' : 'a' : 'g' : '_' : '_' : []) = tok 8 (CTokGnuC GnuCComplexImag)
idkwtok ('_' : '_' : 'i' : 'n' : 'l' : 'i' : 'n' : 'e' : []) = tok 8 CTokInline
idkwtok ('i' : 'n' : 'l' : 'i' : 'n' : 'e' : []) = tok 6 CTokInline
idkwtok ('_' : '_' : 'i' : 'n' : 'l' : 'i' : 'n' : 'e' : '_' : '_' : []) = tok 10 CTokInline
idkwtok ('i' : 'n' : 't' : []) = tok 3 CTokInt
idkwtok ('_' : '_' : 'i' : 'n' : 't' : '1' : '2' : '8' : []) = tok 8 CTokInt128
idkwtok ('_' : '_' : 'i' : 'n' : 't' : '1' : '2' : '8' : '_' : 't' : []) = tok 10 CTokInt128
idkwtok ('_' : '_' : 'l' : 'a' : 'b' : 'e' : 'l' : '_' : '_' : []) = tok 9 CTokLabel
idkwtok ('l' : 'o' : 'n' : 'g' : []) = tok 4 CTokLong
idkwtok ('_' : '_' : 'n' : 'o' : 'n' : 'n' : 'u' : 'l' : 'l' : []) = tok 9 CTokNonnull
idkwtok ('_' : '_' : 'n' : 'u' : 'l' : 'l' : 'a' : 'b' : 'l' : 'e' : []) = tok 10 CTokNullable
idkwtok ('_' : '_' : 'r' : 'e' : 'a' : 'l' : []) = tok 6 (CTokGnuC GnuCComplexReal)
idkwtok ('_' : '_' : 'r' : 'e' : 'a' : 'l' : '_' : '_' : []) = tok 8 (CTokGnuC GnuCComplexReal)
idkwtok ('r' : 'e' : 'g' : 'i' : 's' : 't' : 'e' : 'r' : []) = tok 8 CTokRegister
idkwtok ('_' : '_' : 'r' : 'e' : 's' : 't' : 'r' : 'i' : 'c' : 't' : []) = tok 10 CTokRestrict
idkwtok ('r' : 'e' : 's' : 't' : 'r' : 'i' : 'c' : 't' : []) = tok 8 CTokRestrict
idkwtok ('_' : '_' : 'r' : 'e' : 's' : 't' : 'r' : 'i' : 'c' : 't' : '_' : '_' : []) = tok 12 CTokRestrict
idkwtok ('r' : 'e' : 't' : 'u' : 'r' : 'n' : []) = tok 6 CTokReturn
idkwtok ('s' : 'h' : 'o' : 'r' : 't' : []) = tok 5 CTokShort
idkwtok ('_' : '_' : 's' : 'i' : 'g' : 'n' : 'e' : 'd' : []) = tok 8 CTokSigned
idkwtok ('s' : 'i' : 'g' : 'n' : 'e' : 'd' : []) = tok 6 CTokSigned
idkwtok ('_' : '_' : 's' : 'i' : 'g' : 'n' : 'e' : 'd' : '_' : '_' : []) = tok 10 CTokSigned
idkwtok ('s' : 'i' : 'z' : 'e' : 'o' : 'f' : []) = tok 6 CTokSizeof
idkwtok ('s' : 't' : 'a' : 't' : 'i' : 'c' : []) = tok 6 CTokStatic
idkwtok ('s' : 't' : 'r' : 'u' : 'c' : 't' : []) = tok 6 CTokStruct
idkwtok ('s' : 'w' : 'i' : 't' : 'c' : 'h' : []) = tok 6 CTokSwitch
idkwtok ('_' : '_' : 't' : 'h' : 'r' : 'e' : 'a' : 'd' : []) = tok 8 CTokThread
idkwtok ('t' : 'y' : 'p' : 'e' : 'd' : 'e' : 'f' : []) = tok 7 CTokTypedef
idkwtok ('_' : '_' : 't' : 'y' : 'p' : 'e' : 'o' : 'f' : []) = tok 8 CTokTypeof
idkwtok ('t' : 'y' : 'p' : 'e' : 'o' : 'f' : []) = tok 6 CTokTypeof
idkwtok ('_' : '_' : 't' : 'y' : 'p' : 'e' : 'o' : 'f' : '_' : '_' : []) = tok 10 CTokTypeof
idkwtok ('_' : '_' : 'u' : 'i' : 'n' : 't' : '1' : '2' : '8' : []) = tok 9 (CTokUInt128)
idkwtok ('_' : '_' : 'u' : 'i' : 'n' : 't' : '1' : '2' : '8' : '_' : 't' : []) = tok 11 (CTokUInt128)
idkwtok ('u' : 'n' : 'i' : 'o' : 'n' : []) = tok 5 CTokUnion
idkwtok ('u' : 'n' : 's' : 'i' : 'g' : 'n' : 'e' : 'd' : []) = tok 8 CTokUnsigned
idkwtok ('v' : 'o' : 'i' : 'd' : []) = tok 4 CTokVoid
idkwtok ('_' : '_' : 'v' : 'o' : 'l' : 'a' : 't' : 'i' : 'l' : 'e' : []) = tok 10 CTokVolatile
idkwtok ('v' : 'o' : 'l' : 'a' : 't' : 'i' : 'l' : 'e' : []) = tok 8 CTokVolatile
idkwtok ('_' : '_' : 'v' : 'o' : 'l' : 'a' : 't' : 'i' : 'l' : 'e' : '_' : '_' : []) = tok 12 CTokVolatile
idkwtok ('w' : 'h' : 'i' : 'l' : 'e' : []) = tok 5 CTokWhile

-- For OpenCL tokens
idkwtok ('_' : '_' : 'k' : 'e' : 'r' : 'n' : 'e' : 'l' : []) = tok 8 CTokClKernel
idkwtok ('_' : '_' : 'r' : 'e' : 'a' : 'd' : '_' : 'o' : 'n' : 'l' : 'y' : []) = tok 11 CTokClRdOnly
idkwtok ('_' : '_' : 'w' : 'r' : 'i' : 't' : 'e' : '_' : 'o' : 'n' : 'l' : 'y' : []) = tok 12 CTokClWrOnly
idkwtok ('_' : '_' : 'g' : 'l' : 'o' : 'b' : 'a' : 'l' : []) = tok 8 CTokClGlobal
idkwtok ('_' : '_' : 'l' : 'o' : 'c' : 'a' : 'l' : []) = tok 7 CTokClLocal

idkwtok cs = \pos -> do
  name <- getNewName
  let len = case length cs of l -> l
  let ident = mkIdent pos cs name
  tyident <- isTypeIdent ident
  if tyident
    then return (CTokTyIdent (pos,len) ident)
    else return (CTokIdent   (pos,len) ident)

ignoreAttribute :: P ()
ignoreAttribute = skipTokens (0::Int)
  where skipTokens :: Int -> P ()
        skipTokens n = do
          ntok <- lexToken' False
          case ntok of
            CTokRParen _ | n == 1    -> return ()
                         | otherwise -> skipTokens (n-1)
            CTokLParen _             -> skipTokens (n+1)
            _                        -> skipTokens n

tok :: Int -> (PosLength -> CToken) -> Position -> P CToken
tok len tc pos = return (tc (pos,len))

adjustLineDirective :: Int -> String -> Position -> Position
adjustLineDirective pragmaLen str pos =
    offs' `seq` fname' `seq` row' `seq` parent' `seq` (position offs' fname' row' 1 parent')
    where
    -- offset changes by length of #line pragma
    offs'           = (posOffset pos) + pragmaLen
    str'            = dropWhite . drop 1 $ str
    (rowStr, str'') = span isDigit str'
    -- row changes to the first number in the line pragma
    row'      = read rowStr
    str'''      = dropWhite str''
    (fnameStr,str'''') = span (/= '"') . drop 1 $ str'''
    fname = posFile pos
    no_fn = null str''' || (fmap fst (uncons str''') /= Just '"') || (fmap fst (uncons str'''') /= Just '"')
    -- filename changes to new filename, if specified
    fname' | no_fn = fname
           -- try and get more sharing of file name strings
           | fnameStr == fname     = fname
           | otherwise             = fnameStr
    -- analye flags
    min_flag = find_min_flag (5 :: Int) (drop 1 str'''')
    find_min_flag cur_min = select_min . span isDigit . dropWhile (not . isDigit)
      where
        select_min (numStr, fstr') | null numStr = cur_min
                                   | otherwise = find_min_flag (read numStr `min` cur_min) fstr'
    parent = posParent pos
    parent' = case min_flag of
                1 -> Just pos -- push
                2 -> case parent >>= posParent of
                         Nothing -> Nothing          -- pop/underflow
                         Just gp -> gp `seq` Just gp -- pop
                3 -> parent   -- unchanged stack, system header info
                4 -> parent   -- unchanged stack, extern C info
                _ -> Nothing
    --
    dropWhite = dropWhile (\c -> c == ' ' || c == '\t')

-- special utility for the lexer
unescapeMultiChars :: String -> [Char]
unescapeMultiChars cs@(_ : _ : _) = case unescapeChar cs of (c,cs') -> c : unescapeMultiChars cs'
unescapeMultiChars ('\'' : []) = []
unescapeMultiChars _ = error "Unexpected end of multi-char constant"

{-# INLINE token_ #-}
-- token that ignores the string
token_ :: Int -> (PosLength -> CToken) -> Position -> Int -> InputStream -> P CToken
token_ len mkTok pos _ _ = return (mkTok (pos,len))

{-# INLINE token_fail #-}
-- error token
token_fail :: String -> Position ->
              Int -> InputStream -> P CToken
token_fail errmsg pos _ _ =   failP pos [ "Lexical Error !", errmsg ]


{-# INLINE token #-}
-- token that uses the string
token :: (PosLength -> a -> CToken) -> (String -> a)
      -> Position -> Int -> InputStream -> P CToken
token mkTok fromStr pos len str = return (mkTok (pos,len) (fromStr $ takeChars len str))

{-# INLINE token_plus #-}
-- token that may fail
token_plus :: (PosLength -> a -> CToken) -> (String -> Either String a)
      -> Position -> Int -> InputStream -> P CToken
token_plus mkTok fromStr pos len str =
  case fromStr (takeChars len str) of Left err -> failP pos [ "Lexical error ! ", err ]
                                      Right ok -> return $! mkTok (pos,len) ok

-- -----------------------------------------------------------------------------
-- The input type

type AlexInput = (Position,   -- current position,
                  InputStream)     -- current input string

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar _ = error "alexInputPrevChar not used"

-- for alex-3.0
alexGetByte :: AlexInput -> Maybe (Word8, AlexInput)
alexGetByte (p,is) | inputStreamEmpty is = Nothing
                   | otherwise  = let (b,s) = takeByte is in
                                  -- this is safe for latin-1, but ugly
                                  let p' = alexMove p (chr (fromIntegral b)) in p' `seq`
                                  Just (b, (p', s))

alexGetChar :: AlexInput -> Maybe (Char,AlexInput)
alexGetChar (p,is) | inputStreamEmpty is = Nothing
                   | otherwise  = let (c,s) = takeChar is in
                                  let p' = alexMove p c in p' `seq`
                                  Just (c, (p', s))

alexMove :: Position -> Char -> Position
alexMove pos ' '  = incPos pos 1
alexMove pos '\n' = retPos pos
alexMove pos '\r' = incOffset pos 1
alexMove pos _    = incPos pos 1

lexicalError :: P a
lexicalError = do
  pos <- getPos
  (c,_) <- liftM takeChar getInput
  failP pos
        ["Lexical error !",
         "The character " ++ show c ++ " does not fit here."]

parseError :: P a
parseError = do
  lastTok <- getLastToken
  failP (posOf lastTok)
        ["Syntax error !",
         "The symbol `" ++ show lastTok ++ "' does not fit here."]

-- there is a problem with ignored tokens here (that aren't skipped)
-- consider
-- 1 > int x;
-- 2 > LINE "ex.c" 4
-- 4 > int y;
-- when we get to LINE, we have [int (1,1),x (1,4)] in the token cache.
-- Now we run
-- > action  (pos 2,0) 14 "LINE \"ex.c\" 3\n"
-- which in turn adjusts the position and then calls lexToken again
-- we get `int (pos 4,0)', and have [x (1,4), int (4,1) ] in the token cache (fine)
-- but then, we again call setLastToken when returning and get [int (4,1),int (4,1)] in the token cache (bad)
-- to resolve this, recursive calls invoke lexToken' False.
lexToken :: P CToken
lexToken = lexToken' True

lexToken' :: Bool -> P CToken
lexToken' modifyCache = do
  pos <- getPos
  inp <- getInput
  case alexScan (pos, inp) 0 of
    AlexEOF -> do
        handleEofToken
        return CTokEof
    AlexError _inp -> lexicalError
    AlexSkip  (pos', inp') _len -> do
        setPos pos'
        setInput inp'
        lexToken' modifyCache
    AlexToken (pos', inp') len action -> do
        setPos pos'
        setInput inp'
        nextTok <- action pos len inp
        when modifyCache $ setLastToken nextTok
        return nextTok

lexC :: (CToken -> P a) -> P a
lexC cont = do
  nextTok <- lexToken
  cont nextTok
}
