cmake_minimum_required(VERSION 3.22)
project(mesh_noise LANGUAGES C CXX)
set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 17)
add_library(mesh_noise SHARED mesh_noise.cpp
  rnnoise/src/denoise.c rnnoise/src/rnn.c rnnoise/src/rnn_data.c
  rnnoise/src/rnn_reader.c rnnoise/src/pitch.c rnnoise/src/kiss_fft.c
  rnnoise/src/celt_lpc.c)
target_include_directories(mesh_noise PRIVATE rnnoise/include rnnoise/src)
target_compile_definitions(mesh_noise PRIVATE RNNOISE_BUILD)
target_compile_options(mesh_noise PRIVATE -O3 -fvisibility=hidden)
target_link_libraries(mesh_noise m)
