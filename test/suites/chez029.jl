using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez029" begin
    check_case("chez029")
end
