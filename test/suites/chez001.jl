using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez001" begin
    check_case("chez001")
end
