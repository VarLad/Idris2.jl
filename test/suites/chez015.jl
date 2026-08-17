using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez015" begin
    check_case("chez015")
end
