# ctypes bindings to meshopt.dll = the vendored Packages/MeshOptimizer C++ + memshim.cpp (build line: README.md).
import os
import ctypes
from ctypes import c_size_t, c_float, c_uint, c_void_p, POINTER

lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "meshopt.dll"))
lib.meshopt_generateVertexRemap.restype = c_size_t
lib.meshopt_generateVertexRemap.argtypes = [c_void_p, c_void_p, c_size_t, c_void_p, c_size_t, c_size_t]
lib.meshopt_simplify.restype = c_size_t
lib.meshopt_simplify.argtypes = [c_void_p, c_void_p, c_size_t, c_void_p, c_size_t, c_size_t, c_size_t, c_float, c_uint, POINTER(c_float)]
lib.meshopt_simplifyWithAttributes.restype = c_size_t
lib.meshopt_simplifyWithAttributes.argtypes = [c_void_p, c_void_p, c_size_t, c_void_p, c_size_t, c_size_t,
    c_void_p, c_size_t, c_void_p, c_size_t, c_void_p, c_size_t, c_float, c_uint, POINTER(c_float)]
lib.meshopt_optimizeVertexFetchRemap.restype = c_size_t
lib.meshopt_optimizeVertexFetchRemap.argtypes = [c_void_p, c_void_p, c_size_t, c_size_t]
# memshim.cpp: counting allocator -> peak bytes allocated inside the library
lib.shim_install()
lib.shim_peak.restype = c_size_t
lib.shim_live.restype = c_size_t

Sparse = 2  # meshopt_SimplifySparse
FLT_MAX = 3.4028234663852886e38


def ptr(a):
    return a.ctypes.data_as(c_void_p)
