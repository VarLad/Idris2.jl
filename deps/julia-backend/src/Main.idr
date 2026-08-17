module Main

import Compiler.Common
import Compiler.Julia
import Idris.Driver

main : IO ()
main = mainWithCodegens [("julia", codegenJulia)]
