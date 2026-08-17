using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "integer_array" begin
    check_case("integer_array")
end
