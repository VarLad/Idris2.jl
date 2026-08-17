using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "idiom001" begin
    check_case("idiom001")
end
