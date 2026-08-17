using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "perf006" begin
    check_case("perf006")
end
