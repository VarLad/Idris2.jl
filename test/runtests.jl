using Idris2
using ParallelTestRunner

# Each test case is a file in test/suites/; ParallelTestRunner runs them in
# parallel worker processes. Run with `--jobs=7` (or another value) to control
# the number of workers, e.g.:
#
#   julia --project=. test/runtests.jl --jobs=7
#
# or via Pkg.test(test_args=["--jobs=7"]).
const SUITES_DIR = joinpath(@__DIR__, "suites")

runtests(Idris2, ARGS; testsuite = ParallelTestRunner.find_tests(SUITES_DIR))
