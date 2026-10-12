cmake_minimum_required(VERSION 3.25)
project(Skate2Launcher VERSION 0.1.1 LANGUAGES CXX RC)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "The launcher requires a 64-bit Windows toolchain.")
endif()

add_executable(skate2_launcher WIN32 src/main.cpp src/launcher.rc)
target_compile_features(skate2_launcher PRIVATE cxx_std_17)
target_compile_definitions(skate2_launcher PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(skate2_launcher PRIVATE shell32 user32)
set_target_properties(skate2_launcher PROPERTIES
  OUTPUT_NAME "Launch Skate 2"
  MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
if(MSVC)
  target_compile_options(skate2_launcher PRIVATE /W4 /utf-8 /permissive-)
endif()
