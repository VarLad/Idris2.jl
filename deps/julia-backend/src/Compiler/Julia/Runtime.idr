module Compiler.Julia.Runtime

import Data.String

%default total

||| Julia runtime support code. This is embedded into every generated
||| Julia module so that the output is self contained and does not need
||| any additional support files at runtime.
export
juliaRuntime : String
juliaRuntime = """
# Idris 2 generated Julia runtime
struct IdrisError <: Exception
    msg::String
end

# Every Idris data constructor is represented by this single fixed type.
# `tag` is an Int for data constructors, or a Symbol for type constructors.
# `args` is a tuple of the constructor's fields.
struct Val
    tag::Any
    args::Any
end

function _idris_crash(msg)
    throw(IdrisError(msg))
end

function _idris_tailRec(@nospecialize(f), @nospecialize(ini))
    obj = ini
    while obj.tag != 0
        obj = f(obj)
    end
    return obj.args[1]
end

function _idris_div(a::T, b::T) where {T<:Integer}
    b == 0 && _idris_crash("division by zero")
    if T === BigInt
        return b > 0 ? fld(a, b) : cld(a, b)
    end
    q = b > 0 ? fld(BigInt(a), BigInt(b)) : cld(BigInt(a), BigInt(b))
    return _idris_wrap_to(T, q)
end

function _idris_mod(a::T, b::T) where {T<:Integer}
    b == 0 && _idris_crash("division by zero")
    if T === BigInt
        return a - b * _idris_div(a, b)
    end
    q = b > 0 ? fld(BigInt(a), BigInt(b)) : cld(BigInt(a), BigInt(b))
    return _idris_wrap_to(T, BigInt(a) - BigInt(b) * q)
end

function _idris_strHead(s)
    return first(s)
end

function _idris_strTail(s)
    return chop(s; head = 1, tail = 0)
end

function _idris_strIndex(s, i)
    return collect(s)[i + 1]
end

function _idris_strCons(c, s)
    return string(c) * s
end

function _idris_strReverse(s)
    return reverse(s)
end

function _idris_strSubstr(o, l, s)
    return String(collect(s)[(o + 1):(o + l)])
end

function _idris_parse_double(s)
    try
        x = parse(Float64, s)
        return x == 0 ? 0.0 : x  # normalise -0.0 to 0.0
    catch
        return 0.0
    end
end

function _idris_parse_bigint(s)
    try
        if occursin('.', s) || occursin('e', s) || occursin('E', s)
            return _idris_integer(BigInt(trunc(parse(Float64, s))))
        else
            return _idris_integer(parse(BigInt, s))
        end
    catch
        return Int64(0)
    end
end

# Idris `Integer`/`Nat` are unbounded, but most values are small. We represent
# them as a small-integer union (Int64 fast path, BigInt fallback), mirroring
# Chez Scheme's fixnum/bignum split.
const IdrisInteger = Union{Int64, BigInt}

function _idris_integer(x::Integer)
    if typemin(Int64) <= x <= typemax(Int64)
        return Int64(x)
    else
        return BigInt(x)
    end
end

function _idris_iadd(a::IdrisInteger, b::IdrisInteger)
    if a isa Int64 && b isa Int64
        r, o = Base.add_with_overflow(a, b)
        return o ? BigInt(a) + BigInt(b) : r
    end
    return BigInt(a) + BigInt(b)
end

function _idris_isub(a::IdrisInteger, b::IdrisInteger)
    if a isa Int64 && b isa Int64
        r, o = Base.sub_with_overflow(a, b)
        return o ? BigInt(a) - BigInt(b) : r
    end
    return BigInt(a) - BigInt(b)
end

function _idris_imul(a::IdrisInteger, b::IdrisInteger)
    if a isa Int64 && b isa Int64
        r, o = Base.mul_with_overflow(a, b)
        return o ? BigInt(a) * BigInt(b) : r
    end
    return BigInt(a) * BigInt(b)
end

function _idris_ineg(a::IdrisInteger)
    if a isa Int64
        return a == typemin(Int64) ? BigInt(9223372036854775808) : -a
    end
    return -a
end

function _idris_idiv(a::IdrisInteger, b::IdrisInteger)
    b == 0 && _idris_crash("division by zero")
    q = b > 0 ? fld(BigInt(a), BigInt(b)) : cld(BigInt(a), BigInt(b))
    return _idris_integer(q)
end

function _idris_imod(a::IdrisInteger, b::IdrisInteger)
    b == 0 && _idris_crash("division by zero")
    q = b > 0 ? fld(BigInt(a), BigInt(b)) : cld(BigInt(a), BigInt(b))
    return _idris_integer(BigInt(a) - BigInt(b) * q)
end

function _idris_ishl(a::IdrisInteger, b::IdrisInteger)
    b < 0 && _idris_crash("negative shift")
    return _idris_integer(BigInt(a) << Int(b))
end

function _idris_ishr(a::IdrisInteger, b::IdrisInteger)
    b < 0 && _idris_crash("negative shift")
    return _idris_integer(BigInt(a) >> Int(b))
end

_idris_iand(a::IdrisInteger, b::IdrisInteger) = _idris_integer(BigInt(a) & BigInt(b))
_idris_ior(a::IdrisInteger, b::IdrisInteger)  = _idris_integer(BigInt(a) | BigInt(b))
_idris_ixor(a::IdrisInteger, b::IdrisInteger) = _idris_integer(xor(BigInt(a), BigInt(b)))

function _idris_int_to_char(x)
    if (x >= 0 && x <= 0xd7ff) || (x >= 0xe000 && x <= 0x10ffff)
        return Char(Int(x))
    else
        return Char(0)
    end
end

_idris_wrap_to(::Type{Int8}, x) = _idris_wrap_int8(x)
_idris_wrap_to(::Type{Int16}, x) = _idris_wrap_int16(x)
_idris_wrap_to(::Type{Int32}, x) = _idris_wrap_int32(x)
_idris_wrap_to(::Type{Int64}, x) = _idris_wrap_int64(x)
_idris_wrap_to(::Type{UInt8}, x) = _idris_wrap_uint8(x)
_idris_wrap_to(::Type{UInt16}, x) = _idris_wrap_uint16(x)
_idris_wrap_to(::Type{UInt32}, x) = _idris_wrap_uint32(x)
_idris_wrap_to(::Type{UInt64}, x) = _idris_wrap_uint64(x)
_idris_wrap_to(::Type{BigInt}, x) = x

_idris_wrap_int8(x) = reinterpret(Int8, UInt8(mod(x, 256)))
_idris_wrap_int16(x) = reinterpret(Int16, UInt16(mod(x, 65536)))
_idris_wrap_int32(x) = reinterpret(Int32, UInt32(mod(x, 4294967296)))
_idris_wrap_int64(x) = reinterpret(Int64, UInt64(mod(x, BigInt(2)^64)))
_idris_wrap_uint8(x) = UInt8(mod(x, 256))
_idris_wrap_uint16(x) = UInt16(mod(x, 65536))
_idris_wrap_uint32(x) = UInt32(mod(x, 4294967296))
_idris_wrap_uint64(x) = UInt64(mod(x, BigInt(2)^64))

function _idris_newIORef(v)
    return Ref{Any}(v)
end

function _idris_readIORef(r)
    return r[]
end

function _idris_writeIORef(r, v)
    r[] = v
    return nothing
end

function _idris_newArray(n, v)
    a = Vector{Any}(undef, Int(n))
    fill!(a, v)
    return a
end

function _idris_arrayGet(a, i)
    return a[Int(i) + 1]
end

function _idris_arraySet(a, i, v)
    a[Int(i) + 1] = v
    return nothing
end

_idris_os() = Sys.iswindows() ? "windows" : "unix"

_idris_log(x) = try
    log(x)
catch
    NaN
end

_idris_sqrt(x) = try
    sqrt(x)
catch
    NaN
end

_idris_asin(x) = try
    asin(x)
catch
    NaN
end

_idris_acos(x) = try
    acos(x)
catch
    NaN
end

_idris_pow(x, y) = try
    x ^ y
catch
    NaN
end

function _idris_fastUnpack(s)
    result = Val(0, ())
    for c in reverse(collect(s))
        result = Val(1, (c, result))
    end
    return result
end

function _idris_fastPack(@nospecialize(xs))
    cs = Char[]
    while xs.tag != 0
        push!(cs, xs.args[1])
        xs = xs.args[2]
    end
    return String(cs)
end

function _idris_fastConcat(@nospecialize(xs))
    ss = String[]
    while xs.tag != 0
        push!(ss, xs.args[1])
        xs = xs.args[2]
    end
    return join(ss)
end
"""
