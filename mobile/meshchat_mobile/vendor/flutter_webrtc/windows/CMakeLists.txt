cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "flutter_webrtc")
project(${PROJECT_NAME} LANGUAGES C CXX)

if (CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
  cmake_policy(SET CMP0135 NEW)
endif()

# Add the libwebrtc dependency
include("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/CMakeLists.txt")

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_webrtc_plugin")

add_definitions(-DLIB_WEBRTC_API_DLL)
add_definitions(-DRTC_DESKTOP_DEVICE)

add_library(${PLUGIN_NAME} SHARED
  "../common/cpp/src/flutter_common.cc"
  "../common/cpp/src/flutter_data_channel.cc"
  "../common/cpp/src/flutter_data_packet_cryptor.cc"
  "../common/cpp/src/flutter_frame_cryptor.cc"
  "../common/cpp/src/flutter_media_stream.cc"
  "../common/cpp/src/flutter_utf8_sanitize.cc"
  "../common/cpp/src/flutter_peerconnection.cc"
  "../common/cpp/src/flutter_frame_capturer.cc"
  "../common/cpp/src/flutter_video_renderer.cc"
  "../common/cpp/src/flutter_screen_capture.cc"
  "../common/cpp/src/flutter_webrtc.cc"
  "../common/cpp/src/flutter_webrtc_base.cc"
  "application_loopback_capturer.cc"
  "loopback_capturer_factory.cc"
  "flutter_webrtc_plugin.cc"
  "task_runner_windows.cc"
)

include_directories(
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/svpng"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)

apply_standard_settings(${PLUGIN_NAME})
set(MESH_NOISE "${CMAKE_CURRENT_SOURCE_DIR}/../ios/flutter_webrtc/Sources/flutter_webrtc/MeshRNNoise")
add_library(mesh_rnnoise STATIC
  "${MESH_NOISE}/src/denoise.c" "${MESH_NOISE}/src/rnn.c"
  "${MESH_NOISE}/src/rnn_data.c" "${MESH_NOISE}/src/rnn_reader.c"
  "${MESH_NOISE}/src/pitch.c" "${MESH_NOISE}/src/kiss_fft.c"
  "${MESH_NOISE}/src/celt_lpc.c")
target_include_directories(mesh_rnnoise PUBLIC "${MESH_NOISE}/include" PRIVATE "${MESH_NOISE}/src")
target_compile_definitions(mesh_rnnoise PRIVATE RNNOISE_BUILD _USE_MATH_DEFINES)
target_compile_definitions(${PLUGIN_NAME} PRIVATE MESH_RNNOISE)
target_link_libraries(${PLUGIN_NAME} PRIVATE mesh_rnnoise)
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/cpp/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE 
  flutter
  flutter_wrapper_plugin
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll.lib"
  avrt.lib
  ksuser.lib
  mmdevapi.lib
  ole32.lib
  runtimeobject.lib
  uuid.lib
  winmm.lib
)

# List of absolute paths to libraries that should be bundled with the plugin
set(flutter_webrtc_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libwebrtc/lib/libwebrtc.dll"
  PARENT_SCOPE
)
