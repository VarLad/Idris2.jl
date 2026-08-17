using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node001" begin
    check_case("node001")
end
