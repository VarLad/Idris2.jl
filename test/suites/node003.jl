using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node003" begin
    check_case("node003")
end
