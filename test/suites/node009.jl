using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node009" begin
    check_case("node009")
end
