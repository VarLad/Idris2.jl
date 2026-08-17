using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node022" begin
    check_case("node022")
end
