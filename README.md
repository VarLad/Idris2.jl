# Idris2.jl

A Julia package for compiling and running Idris 2 source strings inside an
existing Julia process, powered by the `idris2jl` code generator (an external
Idris2 backend that emits self-contained Julia modules).

```
Idris2.jl/
├── Project.toml
├── src/Idris2.jl      # the loader package (Julia)
├── deps/
│   ├── build.jl       # Pkg.build script
│   └── julia-backend/ # the code generator source (Idris2)
└── test/              # golden tests (Julia Test + ParallelTestRunner)
```

## Installation

The backend is built automatically by `Pkg.build("Idris2")` (run on
install/update). This requires an Idris 2 installation with the `idris2` API
library installed (present in the normal distribution); set
`IDRIS2=/path/to/idris2` if `idris2` is not on `PATH`.

```julia
import Pkg
Pkg.develop(path = "/path/to/IdrisJulia/Idris2.jl")
# or Pkg.add("Idris2") once it is registered

using Idris2
```

The built `idris2jl` executable is installed into a per-user Scratch space
(not into the package tree), and is located by `Idris2.idris2jl_path()` at
load time.

## How it works

`idris2jl` is a full Idris2 compiler with an extra `julia` code generator
registered through `Idris.Driver.mainWithCodegens`. It consumes the
`NamedCExp` IR (`UsePhase = Cases`), the same high-level IR used by the Scheme
and JavaScript backends, and emits a single self-contained Julia `module`.

Key design choices:

- **Values** are Julia tuples. A data constructor `C a b` with tag `t` becomes
  `(t, a, b)`; a record becomes `(f1, f2, ...)`; `()` and erased values become
  `nothing`.
- **Tail calls** use `Compiler.ES.TailRec` plus a small `_idris_tailRec`
  trampoline, so mutually tail-recursive functions don't overflow the stack.
- **The runtime** is embedded directly into every generated module
  (`deps/julia-backend/src/Compiler/Julia/Runtime.idr`), so the output has no
  external Julia dependencies.
- **FFI** supports inline `julia:lambda:` and `julia:support:` specifiers.
  A few core `Prelude.IO` primitives (`prim__putStr`, `prim__putChar`,
  `prim__getStr`) are implemented natively so basic IO works without modifying
  the standard library.

## Building the backend manually

```bash
cd deps/julia-backend
idris2 --build julia-backend.ipkg
# produces build/exec/idris2jl
```

## CLI usage

`idris2jl` is the `idris2` driver with the `julia` code generator:

```bash
# compile Main.idr to a Julia module
idris2jl --cg julia Main.idr -o Main

# run it
julia -e 'include("Main.jl"); IdrisMain.main()'

# or compile and execute directly
idris2jl --cg julia Main.idr --exec main
```

## Loading in Julia

```julia
using Idris2

# `idris2jl` is auto-detected from the Pkg.build Scratch space; override it
# explicitly only if needed:
# Idris2.idris2jl!(Idris2.idris2jl_path())  # or "/path/to/idris2jl"

# compile an Idris module from a string and get a Julia Module back
M = Idris2.compile("""
module Main

add : Int -> Int -> Int
add a b = a + b

main : IO ()
main = putStrLn (show (add 2 3))
""")

M.main()          # prints 5
M.Main_add(2, 3)  # call the compiled function directly

# or compile and run main in one step
Idris2.run("""
module Main
main : IO ()
main = putStrLn "hello"
""")
```

## DSL

Two macro forms are provided on top of `compile`:

### String macro

```julia
M = idris"""
module Main
main : IO ()
main = putStrLn "hello"
"""
M.main()
```

### Block macro

The `@idris` block macro accepts Idris-like declarations written with Julia
syntax:

- `module Name ... end` (native Julia `module`)
- `import Data.List` / `using Data.List`
- `name : Type` and `name(x) = body`
- `if c; a; else; b; end` and `let x = e; body end`
- `@data Name(params) begin ... end` and `@record Name begin ... end`
- `@export "backend:name"` and `@foreign "..."` pragmas
- raw `idris"""..."""` sections for anything the Julia parser cannot express

```julia
M = @idris cg=julia module Main
    import Data.List

    @data MaybeInt begin
        Nothing
        Just(Int)
    end

    square : Int -> Int
    square(x) = x * x

    main : IO()
    main = putStrLn(show(square(7)))
end
M.main()
```

Supported options: `cg=...`, `package=...`/`pkg=...`, `directive=...`, and the
`findipkg` flag.

Because the block is parsed by Julia first, Idris code must use Julia's call
syntax: `f(x, y)` instead of `f x y`, and `IO()` instead of `IO ()`. The DSL
unparses these to Idris juxtaposition (`f x y`, `IO ()`). Anything else can be
written verbatim in an `idris"""..."""` section.

### Library mode and clean names

If a source has no top-level `main`, `compile`/`@idris`/`idris"..."` compile it
as a *library*: all top-level functions are emitted and exposed under clean,
un-mangled names.

```julia
M = @idris begin
    square : Int -> Int
    square(x) = x * x
    add : Int -> Int -> Int
    add(a, b) = a + b
end

M.square(3)   # 9
M.add(10, 32) # 42
```

Programs that define `main` still work as before (`M.main()`), and also get the
clean-name aliases.

## Limitations

- The module name in generated output is fixed to `IdrisMain`.
- Top-level names are still available in mangled form (`Main_add`), but clean
  aliases (`add`) are also emitted. Names that would collide with Julia
  keywords/builtins are given a trailing `_` (e.g. an Idris `eval` becomes
  `eval_`).
- Most of the standard library's foreign functions are compiled to runtime
  crash stubs unless a `julia:` FFI is supplied. Only the core IO primitives
  are wired up so far.
- No incremental/module-level compilation yet.

## Future Work

### Deep non-tail recursion (Julia stack overflow)

Idris functions that recurse in a *non-tail* position build a Julia call
frame per iteration, and Julia has a fixed 8 MB stack. The backend's
`Compiler.ES.TailRec` pass only trampolines tail-recursive (and mutually
tail-recursive) calls, so recursion such as

```idris
filter p (x :: xs) = if p x then x :: filter p xs else filter p xs
```

(the `x ::` branch) or recursion hidden behind `io_bind`
(`atomically lock act >> runFastInc k`) still overflows for large inputs.

This currently affects two excluded golden tests:

- `newints` (`chez/newints`, `IntOps.idr`) — `filter`/`mapMaybe` over a
  ~34,000-element list.
- `chez003` (`IORef.idr`) — `runFastInc`/`runSlowInc` iterating 1,000,000 /
  10,000 times through `io_bind`.

Fixes to investigate: builtin iterative Prelude list/stream combinators
(`filter`, `map`, `foldr`, …), inlining `io_bind` in the tail-call analysis,
launching the generated Julia with a larger stack, and (longer term) a
whole-program CPS/continuation-stack transform.

### Bootstrapping Idris with `Idris2.jl`

The long-term goal is to compile the Idris 2 compiler *itself* with the Julia
backend, so the compiler runs as Julia code and can be embedded in-process
(no `idris2jl` subprocess). Today `Idris2.jl` shells out to `idris2jl`; this
remains the main architectural step toward a fully in-process Idris
compiler.

### Module syntax in the block DSL

Current behavior:

- `@idris module Main ... end` — native Julia `module` syntax (preferred).
- `@idris begin @module Main begin ... end end` — legacy `@module` macro (still
  supported).
- `@idris begin ... end` — no module, defaults to `Main`.

Preferred direction: make the native `module Main ... end` form the only
supported spelling (deprecate `@module`), and eventually support a bare
`module Main` header line (without the trailing `end`) that applies to the
rest of the block, which is closest to Idris's own `module Main` syntax.
