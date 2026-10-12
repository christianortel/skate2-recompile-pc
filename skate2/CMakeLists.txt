# skate2 - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(skate2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(generated/rexglue.cmake)

# Sources
set(SKATE2_SOURCES
    src/main.cpp
    src/crash_diagnostics.cpp
    src/automatic_gpu_selection.cpp
    src/frame_rate.cpp
)

if(WIN32)
    add_executable(skate2 WIN32 ${SKATE2_SOURCES})
    target_link_libraries(skate2 PRIVATE dbghelp dxgi d3d12)
else()
    add_executable(skate2 ${SKATE2_SOURCES})
endif()

rexglue_setup_target(skate2 GPU_PLUGINS xenos)

# Keep source locations for diagnosing native crashes while retaining release
# optimization. Generated guest sources already use line-tables-only debug info.
if(WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    target_compile_options(skate2 PRIVATE -gline-tables-only)
    target_link_options(skate2 PRIVATE "LINKER:/DEBUG:FULL" "LINKER:/OPT:REF" "LINKER:/OPT:ICF")
endif()
