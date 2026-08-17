using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez024" begin
    check_case("chez024")
end
