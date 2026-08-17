using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "node012" begin
    check_case("node012")
end
