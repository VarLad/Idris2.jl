using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "bitops" begin
    check_case("bitops")
end
