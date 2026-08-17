using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node007" begin
    check_case("node007")
end
