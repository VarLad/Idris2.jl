using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "fastConcat" begin
    check_case("fastConcat")
end
