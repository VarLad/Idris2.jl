using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "chez032" begin
    check_case("chez032")
end
