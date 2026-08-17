using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez009" begin
    check_case("chez009")
end
