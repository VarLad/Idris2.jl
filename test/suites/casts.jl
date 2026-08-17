using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "casts" begin
    check_case("casts")
end
