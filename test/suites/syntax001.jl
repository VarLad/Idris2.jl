using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "syntax001" begin
    check_case("syntax001")
end
