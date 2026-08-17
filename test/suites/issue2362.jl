using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "issue2362" begin
    check_case("issue2362")
end
