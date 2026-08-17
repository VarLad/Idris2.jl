using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez008" begin
    check_case("chez008")
end
