cmake_minimum_required(VERSION 3.22)
project(mesh_noise_test LANGUAGES C CXX)
set(CMAKE_C_STANDARD 11)
set(RNN "${CMAKE_CURRENT_LIST_DIR}/../../vendor/flutter_webrtc/ios/flutter_webrtc/Sources/flutter_webrtc/MeshRNNoise")
add_executable(mesh_noise_test noise_test.c
  ${RNN}/src/denoise.c ${RNN}/src/rnn.c ${RNN}/src/rnn_data.c
  ${RNN}/src/rnn_reader.c ${RNN}/src/pitch.c ${RNN}/src/kiss_fft.c ${RNN}/src/celt_lpc.c)
target_include_directories(mesh_noise_test PRIVATE ${RNN}/include ${RNN}/src)
target_compile_definitions(mesh_noise_test PRIVATE RNNOISE_BUILD _USE_MATH_DEFINES)
if(NOT WIN32)
  target_link_libraries(mesh_noise_test m)
endif()
enable_testing()
add_test(NAME mesh_noise_test COMMAND mesh_noise_test)
if(DEFINED MESH_WEBRTC_INCLUDE_DIR)
  add_executable(mesh_noise_adapter_test adapter_test.cpp
    ${RNN}/src/denoise.c ${RNN}/src/rnn.c ${RNN}/src/rnn_data.c
    ${RNN}/src/rnn_reader.c ${RNN}/src/pitch.c ${RNN}/src/kiss_fft.c ${RNN}/src/celt_lpc.c)
  target_include_directories(mesh_noise_adapter_test PRIVATE ${RNN}/include ${RNN}/src
    ${MESH_WEBRTC_INCLUDE_DIR}
    "${CMAKE_CURRENT_LIST_DIR}/../../vendor/flutter_webrtc/common/cpp/include")
  target_compile_definitions(mesh_noise_adapter_test PRIVATE RNNOISE_BUILD _USE_MATH_DEFINES)
  set_property(TARGET mesh_noise_adapter_test PROPERTY CXX_STANDARD 17)
  add_test(NAME mesh_noise_adapter_test COMMAND mesh_noise_adapter_test)
endif()
