module Idris2

import Scratch

export compile, run, idris2jl!, idris2jl_path, @idris, @idris_str

"""
Path to the `idris2jl` compiler executable.

Consulted in order:

1. the value set with [`idris2jl!`](@ref), if different from the default;
2. the `IDRIS2JL` environment variable;
3. the binary installed into a Scratch space by `Pkg.build("Idris2")`, if present;
4. the literal string `"idris2jl"` (looked up on `PATH`).
"""
const IDRIS2JL_PATH = Ref{String}("idris2jl")
const BUILT_IDRIS2JL = Ref{String}("")

"""
    idris2jl!(path::AbstractString)

Set the path to the `idris2jl` compiler executable used by [`compile`](@ref),
[`run`](@ref), and the `idris"..."` / `@idris` macros.
"""
function idris2jl!(path::AbstractString)
    IDRIS2JL_PATH[] = String(path)
    return IDRIS2JL_PATH[]
end

function _idris2jl()
    explicit = IDRIS2JL_PATH[]
    if explicit != "idris2jl"
        return explicit
    end
    env = get(ENV, "IDRIS2JL", nothing)
    env !== nothing && return env
    if BUILT_IDRIS2JL[] != "" && isfile(BUILT_IDRIS2JL[])
        return BUILT_IDRIS2JL[]
    end
    return "idris2jl"
end

function __init__()
    scratch_dir = Scratch.@get_scratch!("idris2jl")
    bin = joinpath(scratch_dir, "idris2jl")
    if isfile(bin)
        BUILT_IDRIS2JL[] = bin
    end
end

"""
    idris2jl_path() -> String

Return the path to the `idris2jl` compiler executable currently in use.
"""
function idris2jl_path()::String
    return _idris2jl()
end

struct IdrisCompileError <: Exception
    msg::String
end

Base.showerror(io::IO, e::IdrisCompileError) = print(io, e.msg)

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

struct Options
    cg::String
    packages::Vector{String}
    directives::Vector{String}
    findipkg::Bool
end

function _options(; cg::AbstractString="julia",
                    packages=String[],
                    directives=String[],
                    findipkg::Bool=false)
    return Options(
        String(cg),
        String[String(p) for p in packages],
        String[String(d) for d in directives],
        Bool(findipkg),
    )
end

# ---------------------------------------------------------------------------
# Compiler invocation
# ---------------------------------------------------------------------------

function _compiler_command(source_name::AbstractString, out::AbstractString,
                           opts::Options; dir::AbstractString)
    exe = _idris2jl()
    args = String[]
    push!(args, "--no-banner")
    isempty(opts.cg) || (push!(args, "--cg"); push!(args, opts.cg))
    for p in opts.packages
        push!(args, "-p"); push!(args, p)
    end
    for d in opts.directives
        push!(args, "--directive"); push!(args, d)
    end
    opts.findipkg && push!(args, "--find-ipkg")
    push!(args, String(source_name))
    push!(args, "-o"); push!(args, String(out))
    return Cmd(`$exe $args`; dir=String(dir))
end

function _run_compiler(cmd::Cmd)
    outbuf = IOBuffer()
    errbuf = IOBuffer()
    p = Base.run(pipeline(ignorestatus(cmd); stdout=outbuf, stderr=errbuf))
    out = String(take!(outbuf))
    err = String(take!(errbuf))
    if !success(p)
        code = something(p.exitcode, -1)
        details = isempty(out) ? err : out
        msg = "Idris2 compilation failed (exit code $code)\n" * details
        throw(IdrisCompileError(msg))
    end
    return out
end

function _has_main(source::AbstractString)::Bool
    for line in split(String(source), '\n')
        occursin(r"^\s*main\s*[:=]", line) && return true
    end
    return false
end

function _library_source(source::AbstractString)::String
    lines = split(String(source), '\n')
    out = String[]
    for line in lines
        m = match(r"^\s*([a-zA-Z_][a-zA-Z0-9_']*)\s*:", line)
        if m !== nothing && m.captures[1] != "main"
            push!(out, "%export \"julia:$(m.captures[1])\"")
        end
        push!(out, line)
    end
    return join(out, "\n") * "\nmain : IO ()\nmain = pure ()\n"
end

function _julia_code(source::AbstractString, opts::Options)::String
    return mktempdir() do dir
        write(joinpath(dir, "Main.idr"), String(source))
        out = "out"
        cmd = _compiler_command("Main.idr", out, opts; dir=dir)
        _run_compiler(cmd)
        jl = joinpath(dir, "build", "exec", "out.jl")
        isfile(jl) || throw(IdrisCompileError(
            "Idris2 backend did not produce output at $jl"))
        return read(jl, String)
    end
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    compile(source::AbstractString; kwargs...) -> Module

Compile an Idris 2 module (passed as a string) to a Julia module and load it
into the current process. The returned value is the generated Julia `Module`.

The Idris compiler runs as an external process, but the resulting code is
loaded and run in-process.

# Keyword options

- `cg`: code generator to use (default `"julia"`).
- `packages`: extra packages to make visible with `-p`.
- `directives`: extra `--directive` values.
- `findipkg`: enable `--find-ipkg`.
"""
function compile(source::AbstractString; kwargs...)::Module
    opts = _options(; kwargs...)
    src = String(source)
    if !_has_main(src)
        src = _library_source(src)
    end
    code = _julia_code(src, opts)
    return Core.eval(Module(), Meta.parse(code))
end

function _run_module(code::AbstractString)
    m = Module()
    Core.eval(m, Meta.parse(code))
    return Core.eval(m, :(IdrisMain.main()))
end

"""
    run(source::AbstractString; kwargs...)

Compile an Idris 2 module from a string and run its `main` function.
"""
function run(source::AbstractString; kwargs...)
    opts = _options(; kwargs...)
    src = String(source)
    _has_main(src) || throw(ArgumentError("run requires a top-level `main` function"))
    code = _julia_code(src, opts)
    return _run_module(code)
end

# ---------------------------------------------------------------------------
# Idris source generation from a parsed Julia block
# ---------------------------------------------------------------------------

function _idris_string_literal(s::AbstractString)
    buf = IOBuffer()
    write(buf, '"')
    for c in s
        if c == '"'
            write(buf, "\\\"")
        elseif c == '\\'
            write(buf, "\\\\")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\t'
            write(buf, "\\t")
        elseif c == '\r'
            write(buf, "\\r")
        else
            write(buf, c)
        end
    end
    write(buf, '"')
    return String(take!(buf))
end

const INFIX_OPS = Set(["+", "-", "*", "/", "++", "^", "==", "<", "<=", ">", ">=", "&&", "||"])

function _emit_dotted_name(x)
    x isa QuoteNode && (x = x.value)
    x isa Symbol && return String(x)
    return _emit_idris(x)
end

function _emit_import_path(x)
    if x isa Symbol
        return String(x)
    elseif x isa Expr && x.head === :.
        return _emit_import_path(x.args[1]) * "." * _emit_dotted_name(x.args[2])
    elseif x isa Expr && x.head === :as
        return _emit_import_path(x.args[1]) * " as " * String(x.args[2])
    else
        return _emit_idris(x)
    end
end

function _emit_idris(x)
    if x isa LineNumberNode
        return ""
    elseif x isa Symbol
        return String(x)
    elseif x isa AbstractString
        return _idris_string_literal(String(x))
    elseif x isa Number || x isa Bool
        return string(x)
    elseif x isa Char
        return "'" * String(x) * "'"
    elseif x isa Expr
        return _emit_expr(x)
    else
        error("cannot translate to Idris source: $(repr(x))")
    end
end

function _emit_expr(e::Expr)
    if e.head === :block
        parts = String[]
        for a in e.args
            s = _emit_idris(a)
            isempty(s) || push!(parts, s)
        end
        return join(parts, "\n")
    elseif e.head === :call
        return _emit_call(e)
    elseif e.head === :(::)
        return _emit_idris(e.args[1]) * " :: " * _emit_idris(e.args[2])
    elseif e.head === :(->)
        lhs = _emit_idris(e.args[1])
        rhs = _emit_idris(e.args[2])
        return lhs * " -> " * rhs
    elseif e.head === :(=)
        return _emit_idris(e.args[1]) * " = " * _emit_idris(e.args[2])
    elseif e.head === :&& || e.head === :||
        op = e.head === :&& ? "&&" : "||"
        return _emit_idris(e.args[1]) * " " * op * " " * _emit_idris(e.args[2])
    elseif e.head === :tuple
        return "(" * join([_emit_idris(a) for a in e.args], ", ") * ")"
    elseif e.head === :vect
        return "[" * join([_emit_idris(a) for a in e.args], ", ") * "]"
    elseif e.head === :curly
        head = _emit_idris(e.args[1])
        rest = join([_emit_idris(a) for a in e.args[2:end]], " ")
        return isempty(rest) ? head : head * " " * rest
    elseif e.head === :module
        modname = _emit_import_path(e.args[2])
        body = _emit_idris(e.args[3])
        return "module " * modname * "\n" * body * "\n"
    elseif e.head === :.
        return _emit_idris(e.args[1]) * "." * _emit_dotted_name(e.args[2])
    elseif e.head === :import || e.head === :using
        return "import " * _emit_import_path(e.args[1])
    elseif e.head === :if
        cond = _emit_idris(e.args[1])
        th = _emit_idris(e.args[2])
        el = _emit_idris(e.args[3])
        return "if " * cond * " then " * th * " else " * el
    elseif e.head === :comparison
        lhs = _emit_idris(e.args[1])
        clauses = String[]
        i = 2
        while i < length(e.args)
            op = String(e.args[i])
            rhs = _emit_idris(e.args[i + 1])
            push!(clauses, "(" * lhs * " " * op * " " * rhs * ")")
            lhs = rhs
            i += 2
        end
        return join(clauses, " && ")
    elseif e.head === :let
        bindings = _emit_let_bindings(e.args[1])
        body = _emit_idris(e.args[2])
        return "let " * bindings * " in " * body
    elseif e.head === :macrocall
        return _emit_macrocall(e)
    else
        error("unsupported Julia syntax for the Idris DSL: $(e.head) in $(repr(e))")
    end
end

function _emit_let_bindings(x)
    if x isa Expr && x.head === :block
        parts = String[]
        for a in x.args
            a isa LineNumberNode && continue
            push!(parts, _emit_idris(a))
        end
        return join(parts, ", ")
    else
        return _emit_idris(x)
    end
end

function _emit_variants(body)
    parts = String[]
    for stmt in (body isa Expr && body.head === :block ? body.args : Any[body])
        stmt isa LineNumberNode && continue
        s = _emit_idris(stmt)
        isempty(s) || push!(parts, s)
    end
    return parts
end

function _emit_data(head, body)
    h = _emit_idris(head)
    variants = _emit_variants(body)
    isempty(variants) && error("@data requires at least one constructor")
    return "data " * h * " = " * join(variants, " | ")
end

function _emit_record(head, body)
    if head isa Symbol
        name = String(head)
    elseif head isa Expr && head.head === :call
        name = String(head.args[1])
        rest = [ _emit_idris(a) for a in head.args[2:end] ]
        name = isempty(rest) ? name : name * " " * join(rest, " ")
    else
        name = _emit_idris(head)
    end
    ctor = "Mk" * uppercasefirst(name)
    fields = _emit_variants(body)
    lines = ["record " * name * " where", "  constructor " * ctor]
    append!(lines, ["  " * f for f in fields])
    return join(lines, "\n")
end

function _arg_emit(x)
    s = _emit_idris(x)
    if (x isa Number && x < 0) ||
       (x isa Expr && x.head in (:call, :->, :&&, :||, :(=), :curly))
        return "(" * s * ")"
    end
    return s
end

function _emit_call(e::Expr)
    f = e.args[1]
    args = e.args[2:end]
    fs = f isa Symbol ? String(f) : ""

    if f === :(:) && length(args) == 2
        return _emit_idris(args[1]) * " : " * _emit_idris(args[2])
    elseif fs in INFIX_OPS && length(args) >= 2
        return join([_arg_emit(a) for a in args], " " * fs * " ")
    elseif f === :(-) && length(args) == 1
        return "-" * _emit_idris(args[1])
    else
        femit = _emit_idris(f)
        argstrs = [_arg_emit(a) for a in args]
        if isempty(argstrs)
            return femit * "()"
        end
        return femit * " " * join(argstrs, " ")
    end
end

function _emit_macrocall(e::Expr)
    name = e.args[1]
    args = [a for a in e.args[2:end] if !(a isa LineNumberNode)]

    if name === Symbol("@module")
        length(args) == 2 || error("@module expects a name and a begin...end block")
        modname = _emit_idris(args[1])
        body = _emit_idris(args[2])
        return "module " * modname * "\n" * body * "\n"
    elseif name === Symbol("@data")
        length(args) == 2 || error("@data expects a head and a begin...end block")
        return _emit_data(args[1], args[2])
    elseif name === Symbol("@record")
        length(args) == 2 || error("@record expects a head and a begin...end block")
        return _emit_record(args[1], args[2])
    elseif name === Symbol("@export")
        return join(["%export " * _idris_string_literal(String(a)) for a in args], "\n")
    elseif name === Symbol("@foreign")
        return join(["%foreign " * _idris_string_literal(String(a)) for a in args], "\n")
    elseif name === Symbol("@idris_str") || name === Symbol("@raw")
        isempty(args) && return ""
        return String(args[end])
    else
        error("unsupported macro inside @idris block: $name")
    end
end

# ---------------------------------------------------------------------------
# Macros
# ---------------------------------------------------------------------------

function _literal_value(x)
    x isa QuoteNode && (x = x.value)
    if x isa Symbol || x isa AbstractString || x isa Number || x isa Bool
        return x
    elseif x isa Expr && (x.head === :tuple || x.head === :vect)
        return map(_literal_value, x.args)
    end
    throw(ArgumentError("@idris option value must be a literal, got: $x"))
end

function _parse_options(opts)
    kw = Dict{Symbol,Any}()
    for o in opts
        if o isa Symbol
            o === :findipkg || throw(ArgumentError("unknown @idris flag: $o"))
            kw[:findipkg] = true
        elseif o isa Expr && o.head === :(=) && length(o.args) == 2
            key = o.args[1]
            key isa Symbol || throw(ArgumentError("@idris option name must be a symbol: $o"))
            val = _literal_value(o.args[2])
            if key === :cg
                kw[:cg] = string(val)
            elseif key === :package || key === :pkg
                push!(get!(kw, :packages, String[]), string(val))
            elseif key === :directive
                push!(get!(kw, :directives, String[]), string(val))
            else
                throw(ArgumentError("unknown @idris option: $key"))
            end
        else
            throw(ArgumentError("invalid @idris option: $o"))
        end
    end
    return kw
end

function _source_expr(x)
    if x isa AbstractString || x isa Symbol || x isa Number || x isa Bool
        return Expr(:quote, x)
    else
        return esc(x)
    end
end

"""
    @idris [options] begin ... end
    @idris [options] "source"

Compile Idris 2 code to a Julia module at runtime and return the resulting
`Module`.

The block form accepts Idris-like declarations written with Julia syntax
(`name : Type`, `name(x) = body`, `module Name ... end`, `import Data.List`,
`if c; a; else; b; end`, `let x = e; body end`), `@data` / `@record` macros for
declarations, and raw `idris"..."` string sections for anything else.

Supported options are `cg=...`, `package=...` (or `pkg=...`), `directive=...`,
and the `findipkg` flag.

# Example

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
"""
macro idris(args...)
    isempty(args) && throw(ArgumentError("@idris expects a block or a source string"))
    lastarg = args[end]

    if lastarg isa Expr && (lastarg.head === :block || lastarg.head === :module)
        source_expr = Expr(:quote, _emit_idris(lastarg))
    else
        source_expr = _source_expr(lastarg)
    end

    kw = _parse_options(args[1:end-1])
    kwexprs = Expr[]
    for (k, v) in kw
        push!(kwexprs, Expr(:kw, k, Expr(:quote, v)))
    end

    return Expr(:call,
                GlobalRef(@__MODULE__, :compile),
                Expr(:parameters, kwexprs...),
                source_expr)
end

"""
    idris"..."

Non-standard string literal macro. Equivalent to `compile("...")` and returns
the compiled Julia `Module`.
"""
macro idris_str(s)
    return Expr(:call,
                GlobalRef(@__MODULE__, :compile),
                Expr(:quote, s))
end

end # module Idris2
