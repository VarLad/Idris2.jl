using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "reg002" begin
    check_case("reg002")
end
