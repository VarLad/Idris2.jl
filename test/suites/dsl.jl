using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

# The block DSL is tested two ways: unit tests on the unparser (`_emit_idris`)
# for the forms the golden .idr cases cannot cover, plus a few end-to-end
# compile-and-run checks.
#
# Each testset is prefixed with the raw Idris source that the DSL spelling
# expands to, so this file doubles as a reference for the DSL <-> Idris mapping.

function capture_stdout(f)
    mktemp() do path, io
        redirect_stdout(() -> f(), io)
        flush(io)
        return read(path, String)
    end
end

emit(s::AbstractString) = Idris2._emit_idris(Meta.parse(s))

@testset "dsl" begin
    # data MyNat = Z | S MyNat
    #
    # data Maybe a = Nothing | Just a
    @testset "unparser: simple @data" begin
        @test emit("@data MyNat begin Z; S(MyNat) end") == "data MyNat = Z | S MyNat"
        @test emit("@data Maybe(a) begin Nothing; Just(a) end") == "data Maybe a = Nothing | Just a"
    end

    # data Vect : Nat -> Type -> Type where
    #   VNil : Vect Z a
    #   VCons : (x : a) -> (xs : Vect n a) -> Vect (S n) a
    @testset "unparser: GADT @data (where form)" begin
        src = "@data Vect(Nat, Type) begin VNil : Vect(Z, a); " *
              "VCons : (x : a) -> (xs : Vect(n, a)) -> Vect(S(n), a) end"
        @test emit(src) ==
              "data Vect : Nat -> Type -> Type where\n" *
              "  VNil : Vect Z a\n" *
              "  VCons : (x : a) -> (xs : Vect n a) -> Vect (S n) a"
    end

    # (<+>) : (x : a) -> (y : b) -> Prod a b
    # {a : Type} -> (x : a) -> Wrapped a
    # {auto prf : p} -> Dec p
    # {0 prf : p} -> Dec p
    # {1 x : p} -> Dec p
    # {a : Type} -> a
    @testset "unparser: @ctor and binders" begin
        @test emit("@ctor \"(<+>)\" : (x : a) -> (y : b) -> Prod(a, b)") ==
              "(<+>) : (x : a) -> (y : b) -> Prod a b"
        @test emit("@implicit(a, Type) -> (x : a) -> Wrapped(a)") ==
              "{a : Type} -> (x : a) -> Wrapped a"
        @test emit("@auto(prf, p) -> Dec(p)") == "{auto prf : p} -> Dec p"
        @test emit("@erased(prf, p) -> Dec(p)") == "{0 prf : p} -> Dec p"
        @test emit("@linear(x, p) -> Dec(p)") == "{1 x : p} -> Dec p"
        @test emit("{a : Type} -> a") == "{a : Type} -> a"
    end

    # data Vect : Nat -> Type -> Type where
    #   VNil : Vect Z a
    #   VCons : (x : a) -> (xs : Vect n a) -> Vect (S n) a
    #
    # vlen : Vect n a -> Nat
    # vlen VNil = 0
    # vlen (VCons x xs) = 1 + vlen xs
    #
    # main : IO ()
    # main = putStrLn (show (vlen (VCons 1 (VCons 2 (VCons 3 VNil)))))
    @testset "run: GADT Vect" begin
        M = @idris module Main
            @data Vect(Nat, Type) begin
                VNil : Vect(Z, a)
                VCons : (x : a) -> (xs : Vect(n, a)) -> Vect(S(n), a)
            end
            vlen : Vect(n, a) -> Nat
            vlen(VNil) = 0
            vlen(VCons(x, xs)) = 1 + vlen(xs)
            main : IO()
            main = putStrLn(show(vlen(VCons(1, VCons(2, VCons(3, VNil))))))
        end
        @test strip(capture_stdout(() -> M.main())) == "3"
    end

    # data Prod : Type -> Type -> Type where
    #   (<+>) : (x : a) -> (y : b) -> Prod a b
    #
    # pfst : Prod a b -> a
    # pfst ((<+>) x y) = x
    #
    # main : IO ()
    # main = putStrLn (show (pfst ((<+>) 1 2)))
    @testset "run: symbolic constructor via @ctor" begin
        M = @idris module Main
            @data Prod(Type, Type) begin
                @ctor "(<+>)" : (x : a) -> (y : b) -> Prod(a, b)
            end
            pfst : Prod(a, b) -> a
            pfst(var"(<+>)"(x, y)) = x
            main : IO()
            main = putStrLn(show(pfst(var"(<+>)"(1, 2))))
        end
        @test strip(capture_stdout(() -> M.main())) == "1"
    end

    # data Wrapped : Type -> Type where
    #   Wrap : {a : Type} -> (x : a) -> Wrapped a
    #
    # unwrap : Wrapped a -> a
    # unwrap (Wrap x) = x
    #
    # main : IO ()
    # main = putStrLn (show (unwrap (Wrap 42)))
    @testset "run: implicit binder" begin
        M = @idris module Main
            @data Wrapped(Type) begin
                Wrap : @implicit(a, Type) -> (x : a) -> Wrapped(a)
            end
            unwrap : Wrapped(a) -> a
            unwrap(Wrap(x)) = x
            main : IO()
            main = putStrLn(show(unwrap(Wrap(42))))
        end
        @test strip(capture_stdout(() -> M.main())) == "42"
    end

    # data Flags : Type -> Type where
    #   MkErased : {0 prf : Unit} -> (x : a) -> Flags a
    #   MkLinear : {1 prf : Unit} -> (x : a) -> Flags a
    #   MkAuto   : {auto prf : Unit} -> (x : a) -> Flags a
    #
    # data Box : Type -> Type where
    #   MkBox : {a : Type} -> (x : a) -> Box a
    @testset "compile: erased/linear/auto binders and braces" begin
        M_flags = @idris begin
            @data Flags(Type) begin
                MkErased : @erased(prf, Unit) -> (x : a) -> Flags(a)
                MkLinear : @linear(prf, Unit) -> (x : a) -> Flags(a)
                MkAuto   : @auto(prf, Unit) -> (x : a) -> Flags(a)
            end
        end
        @test M_flags isa Module

        M_box = @idris begin
            @data Box(Type) begin
                MkBox : {a : Type} -> (x : a) -> Box(a)
            end
        end
        @test M_box isa Module
    end

    # case n of
    #   0 => "zero"
    #   _ => "other"
    #
    # (\x, y => x + y)
    #
    # do
    #   x <- pure 1
    #   putStrLn (show x)
    #
    # go n where
    #   go 0 = 0
    #   go k = go (k - 1)
    #
    # apply2 : (Int -> Int) -> Int -> Int
    #
    # [1 .. 5]
    #
    # eval (Not t) with (eval t)
    #   eval (Not t) | T = F
    #   eval (Not t) | F = T
    @testset "unparser: expressions" begin
        @test emit("@case n begin 0 => \"zero\"; _ => \"other\" end") ==
              "case n of\n  0 => \"zero\"\n  _ => \"other\""
        @test emit("@lam(x, y, x + y)") == "(\\x, y => x + y)"
        @test emit("@do begin x <- pure(1); putStrLn(show(x)) end") ==
              "do\n  x <- pure 1\n  putStrLn (show x)"
        @test emit("@where go(n) begin go(0) = 0; go(k) = go(k - 1) end") ==
              "go n where\n  go 0 = 0\n  go k = go (k - 1)"
        @test emit("apply2 : (Int -> Int) -> Int -> Int") ==
              "apply2 : (Int -> Int) -> Int -> Int"
        @test emit("[1 .. 5]") == "[1 .. 5]"
        @test emit("@with(eval(Not(t)), eval(t), begin T => F; F => T end)") ==
              "eval (Not t) with (eval t)\n" *
              "  eval (Not t) | T = F\n" *
              "  eval (Not t) | F = T"
    end

    # mutual
    #   f : Int -> Int
    #   f x = g x
    #   g : Int -> Int
    #   g x = f x
    #
    # namespace Ns
    #   x : Int
    #   x = 1
    #
    # parameters (a : Type)
    #   id : a -> a
    #   id x = x
    #
    # interface Display a where
    #   display : a -> String
    #
    # implementation Display Int where
    #   display x = show x
    #
    # rewrite prf in e
    #
    # xs@(x :: _)
    #
    # a ** b
    #
    # %hide Prelude.Nat
    #
    # export answer : Int
    @testset "unparser: blocks and directives" begin
        @test emit("@mutual begin f : Int -> Int; f(x) = g(x); g : Int -> Int; g(x) = f(x) end") ==
              "mutual\n  f : Int -> Int\n  f x = g x\n  g : Int -> Int\n  g x = f x"
        @test emit("@namespace Ns begin x : Int; x = 1 end") ==
              "namespace Ns\n  x : Int\n  x = 1"
        @test emit("@parameters (a : Type) begin id : a -> a; id(x) = x end") ==
              "parameters (a : Type)\n  id : a -> a\n  id x = x"
        @test emit("@interface Display(a) begin display : a -> String end") ==
              "interface Display a where\n  display : a -> String"
        @test emit("@implementation Display(Int) begin display(x) = show(x) end") ==
              "implementation Display Int where\n  display x = show x"
        @test emit("@rewrite(prf, e)") == "rewrite prf in e"
        @test emit("@as(xs, x :: _)") == "xs@(x :: _)"
        @test emit("@dpair(a, b)") == "a ** b"
        @test emit("@pragma(\"%hide Prelude.Nat\")") == "%hide Prelude.Nat"
        @test emit("@vis(\"export\", answer : Int)") == "export answer : Int"
    end

    # describe : Int -> String
    # describe n = case n of
    #   0 => "zero"
    #   1 => "one"
    #   _ => "many"
    #
    # main : IO ()
    # main = putStrLn (describe 0 ++ " " ++ describe 1 ++ " " ++ describe 9)
    #
    # apply2 : (Int -> Int) -> Int -> Int
    # apply2 f x = f (f x)
    #
    # main : IO ()
    # main = putStrLn (show (apply2 (\x => x + 1) 5))
    #
    # main : IO ()
    # main = do
    #   x <- pure 40
    #   y <- pure (x + 2)
    #   putStrLn (show y)
    #
    # fib : Int -> Int
    # fib n = go n where
    #   go : Int -> Int
    #   go 0 = 0
    #   go 1 = 1
    #   go k = go (k - 1) + go (k - 2)
    #
    # main : IO ()
    # main = putStrLn (show (fib 10))
    @testset "run: case/lam/do/where" begin
        M_case = @idris module Main
            describe : Int -> String
            describe(n) = @case n begin
                0 => "zero"
                1 => "one"
                _ => "many"
            end
            main : IO()
            main = putStrLn(describe(0) ++ " " ++ describe(1) ++ " " ++ describe(9))
        end
        @test strip(capture_stdout(() -> M_case.main())) == "zero one many"

        M_lam = @idris module Main
            apply2 : (Int -> Int) -> Int -> Int
            apply2(f, x) = f(f(x))
            main : IO()
            main = putStrLn(show(apply2(@lam(x, x + 1), 5)))
        end
        @test strip(capture_stdout(() -> M_lam.main())) == "7"

        M_do = @idris module Main
            main : IO()
            main = @do begin
                x <- pure(40)
                y <- pure(x + 2)
                putStrLn(show(y))
            end
        end
        @test strip(capture_stdout(() -> M_do.main())) == "42"

        M_where = @idris module Main
            fib : Int -> Int
            fib(n) = @where go(n) begin
                go : Int -> Int
                go(0) = 0
                go(1) = 1
                go(k) = go(k - 1) + go(k - 2)
            end
            main : IO()
            main = putStrLn(show(fib(10)))
        end
        @test strip(capture_stdout(() -> M_where.main())) == "55"
    end

    # data Value = T | F
    #
    # data Term = Const Value | Not Term | If Term Term Term
    #
    # eval : Term -> Value
    # eval (Const v) = v
    # eval (Not t) with (eval t)
    #   eval (Not t) | T = F
    #   eval (Not t) | F = T
    # eval (If c t1 t2) with (eval c)
    #   eval (If c t1 t2) | T = eval t1
    #   eval (If c t1 t2) | F = eval t2
    #
    # toInt : Value -> Int
    # toInt T = 1
    # toInt F = 0
    #
    # main : IO ()
    # main = putStrLn (show (toInt (eval (If (Not (Const T)) (Const F) (Const T)))))
    #
    # total
    # ifCommutes : {c, t1, t2 : Term} ->
    #              eval (If c t1 t2) = eval (If (Not c) t2 t1)
    # ifCommutes with (eval c)
    #   ifCommutes | T = Refl
    #   ifCommutes | F = Refl
    @testset "run: with-notation" begin
        M = @idris module Main
            @data Value begin
                T
                F
            end
            @data Term begin
                Const(Value)
                Not(Term)
                If(Term, Term, Term)
            end

            eval : Term -> Value
            eval(Const(v)) = v
            @with(eval(Not(t)), eval(t), begin
                T => F
                F => T
            end)
            @with(eval(If(c, t1, t2)), eval(c), begin
                T => eval(t1)
                F => eval(t2)
            end)

            toInt : Value -> Int
            toInt(T) = 1
            toInt(F) = 0

            total
            ifCommutes : {c, t1, t2 : Term} -> eval(If(c, t1, t2)) = eval(If(Not(c), t2, t1))
            @with(ifCommutes, eval(c), begin
                T => Refl
                F => Refl
            end)

            main : IO()
            main = putStrLn(show(toInt(eval(If(Not(Const(T)), Const(F), Const(T))))))
        end
        @test strip(capture_stdout(() -> M.main())) == "1"
    end

    # mutual
    #   myEven : Nat -> Bool
    #   myEven Z = True
    #   myEven (S n) = myOdd n
    #   myOdd : Nat -> Bool
    #   myOdd Z = False
    #   myOdd (S n) = myEven n
    #
    # main : IO ()
    # main = putStrLn (show (myEven (S (S (S (S Z))))))
    #
    # namespace Ns
    #   export answer : Int
    #   answer = 42
    #
    # main : IO ()
    # main = putStrLn (show Ns.answer)
    #
    # interface Display a where
    #   display : a -> String
    #
    # implementation Display Int where
    #   display x = show x
    #
    # main : IO ()
    # main = putStrLn (display (the Int 42))
    #
    # main : IO ()
    # main = putStrLn (show [1 .. 5])
    #
    # headInt : List Int -> Int
    # headInt (xs@(x :: _)) = x
    # headInt [] = 0
    #
    # main : IO ()
    # main = putStrLn (show (headInt [1, 2, 3]))
    @testset "run: blocks and ranges" begin
        M_mutual = @idris module Main
            @mutual begin
                myEven : Nat -> Bool
                myEven(Z) = True
                myEven(S(n)) = myOdd(n)
                myOdd : Nat -> Bool
                myOdd(Z) = False
                myOdd(S(n)) = myEven(n)
            end
            main : IO()
            main = putStrLn(show(myEven(S(S(S(S(Z)))))))
        end
        @test strip(capture_stdout(() -> M_mutual.main())) == "True"

        M_ns = @idris module Main
            @namespace Ns begin
                @vis("export", answer : Int)
                answer = 42
            end
            main : IO()
            main = putStrLn(show(Ns.answer))
        end
        @test strip(capture_stdout(() -> M_ns.main())) == "42"

        M_iface = @idris module Main
            @interface Display(a) begin
                display : a -> String
            end
            @implementation Display(Int) begin
                display(x) = show(x)
            end
            main : IO()
            main = putStrLn(display(the(Int, 42)))
        end
        @test strip(capture_stdout(() -> M_iface.main())) == "42"

        M_range = @idris module Main
            main : IO()
            main = putStrLn(show([1 .. 5]))
        end
        @test strip(capture_stdout(() -> M_range.main())) == "[1, 2, 3, 4, 5]"

        M_as = @idris module Main
            headInt : List(Int) -> Int
            headInt(@as(xs, x :: _)) = x
            headInt([]) = 0
            main : IO()
            main = putStrLn(show(headInt([1, 2, 3])))
        end
        @test strip(capture_stdout(() -> M_as.main())) == "1"
    end

    # %hide Prelude.Nat
    # %hide Prelude.Z
    # %hide Prelude.S
    #
    # data Nat = Z | S Nat
    #
    # add : Nat -> Nat -> Nat
    # add Z y = y
    # add (S x) y = S (add x y)
    #
    # main : IO ()
    # main = putStrLn "ok"
    #
    # parameters (a : Type)
    #   myid : a -> a
    #   myid x = x
    @testset "run: %pragma and parameters" begin
        M_hide = @idris module Main
            @pragma("%hide Prelude.Nat", "%hide Prelude.Z", "%hide Prelude.S")
            @data Nat begin
                Z
                S(Nat)
            end
            add : Nat -> Nat -> Nat
            add(Z, y) = y
            add(S(x), y) = S(add(x, y))
            main : IO()
            main = putStrLn("ok")
        end
        @test strip(capture_stdout(() -> M_hide.main())) == "ok"

        M_params = @idris begin
            @parameters (a : Type) begin
                myid : a -> a
                myid(x) = x
            end
        end
        @test M_params isa Module
    end
end
