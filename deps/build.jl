# Build the vendored Idris2 Julia backend and install the resulting executable
# into a per-user Scratch space. Run via `Pkg.build("Idris2")`.
#
# The build happens in a temporary directory (not inside the package tree), so
# this works even when the package is installed read-only from a registry.

import Scratch

backend_dir = joinpath(@__DIR__, "julia-backend")

idris2 = get(ENV, "IDRIS2", "idris2")

# Pre-flight: require the Idris 2 compiler before we fail with an opaque error.
if Sys.which(idris2) === nothing
    error("""
        Idris2.jl could not find the Idris 2 compiler.
        Install Idris 2 (0.8.0) and ensure `idris2` is on PATH, or set
        IDRIS2=/path/to/idris2 to point at the compiler executable.
        """)
end

# Install into the package's Scratch space. We derive the package UUID from
# Project.toml so this path matches `Scratch.@get_scratch!("idris2jl")` inside
# `Idris2.__init__` (which namespaces by the Idris2 package UUID).
project_toml = joinpath(@__DIR__, "..", "Project.toml")
uuid_match = match(r"uuid\s*=\s*\"([^\"]+)\"", read(project_toml, String))
uuid_match === nothing && error("could not find a uuid in $project_toml")
scratch_dir = Scratch.get_scratch!(Base.UUID(uuid_match.captures[1]), "idris2jl")

mktempdir() do tmp
    # Copy only the backend source into the temp dir and build it there.
    src_dir = joinpath(tmp, "julia-backend")
    mkpath(src_dir)
    cp(joinpath(backend_dir, "src"), joinpath(src_dir, "src"))
    cp(joinpath(backend_dir, "julia-backend.ipkg"),
       joinpath(src_dir, "julia-backend.ipkg"))

    Base.run(Cmd(`$idris2 --build julia-backend.ipkg`; dir=src_dir))

    bin = joinpath(src_dir, "build", "exec", "idris2jl")
    isfile(bin) || error("Idris2 backend build did not produce $bin")

    # `idris2jl` is a small shell wrapper that resolves `idris2jl_app/` relative
    # to its own location, so copying the whole `exec/` pair is sufficient.
    mkpath(scratch_dir)
    cp(bin, joinpath(scratch_dir, "idris2jl"); force=true)
    app_dst = joinpath(scratch_dir, "idris2jl_app")
    ispath(app_dst) && rm(app_dst; recursive=true, force=true)
    cp(joinpath(src_dir, "build", "exec", "idris2jl_app"), app_dst)
end

println("Idris2.jl backend installed to ", joinpath(scratch_dir, "idris2jl"))
