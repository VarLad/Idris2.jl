using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node008" begin
    check_case("node008")
end
