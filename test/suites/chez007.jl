using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez007" begin
    check_case("chez007")
end
