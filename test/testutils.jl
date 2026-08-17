# Shared helpers for the golden test suites. Each suite file includes this
# file; it sets up the idris2jl path and provides `check_case`.

using Test
using Idris2

# `Idris2.idris2jl_path()` resolves to the binary installed by `Pkg.build`
# (via a Scratch space), falling back to `idris2jl` on PATH.
const DEFAULT_IDRIS2JL = Idris2.idris2jl_path()

Idris2.idris2jl!(get(ENV, "IDRIS2JL", DEFAULT_IDRIS2JL))

const CASES_DIR = joinpath(@__DIR__, "cases")

function normalize_output(s::AbstractString)
    s = replace(String(s), "\r\n" => "\n")
    lines = [rstrip(l) for l in split(s, '\n')]
    while !isempty(lines) && isempty(last(lines))
        pop!(lines)
    end
    return join(lines, "\n")
end

function idr_files(dir::AbstractString)
    return sort([joinpath(dir, f) for f in readdir(dir) if endswith(f, ".idr")])
end

function case_source(dir::AbstractString)
    files = idr_files(dir)
    isempty(files) && error("no .idr files found in $dir")
    return join([read(f, String) for f in files], "\n")
end

function module_name(src::AbstractString)
    for line in split(String(src), '\n')
        m = match(r"^\s*module\s+([A-Za-z0-9_.]+)", line)
        m !== nothing && return m.captures[1]
    end
    return "Main"
end

function run_idris2_case(src::AbstractString)
    exe = Idris2.idris2jl_path()
    fname = module_name(src) * ".idr"
    return mktempdir() do dir
        write(joinpath(dir, fname), String(src))
        cmd = Cmd(`$exe --no-banner --cg julia --exec main $fname`; dir=dir)
        outbuf = IOBuffer()
        errbuf = IOBuffer()
        p = Base.run(pipeline(ignorestatus(cmd); stdout=outbuf, stderr=errbuf))
        out = String(take!(outbuf))
        err = String(take!(errbuf))
        return (success(p), out, err)
    end
end

# Run one golden case and register the comparison as tests in the current
# testset.
function check_case(name::AbstractString)
    dir = joinpath(CASES_DIR, name)
    src = case_source(dir)
    ok, out, err = run_idris2_case(src)

    if !ok
        error("idris2jl failed for $name:\n$err")
    end

    expected = normalize_output(read(joinpath(dir, "expected"), String))
    actual = normalize_output(out)
    @test actual == expected
end
