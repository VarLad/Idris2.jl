using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez012" begin
    check_case("chez012")
end
