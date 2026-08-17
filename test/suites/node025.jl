using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node025" begin
    check_case("node025")
end
