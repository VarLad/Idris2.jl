using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "reg001" begin
    check_case("reg001")
end
