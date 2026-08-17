using Test
using Idris2
include(joinpath(@__DIR__, "..", "testutils.jl"))

@testset "tailrec001" begin
    check_case("tailrec001")
end
