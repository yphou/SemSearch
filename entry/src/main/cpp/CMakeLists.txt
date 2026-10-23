# SemSearch native module: MNN embedding engine NAPI wrapper
cmake_minimum_required(VERSION 3.5.0)
project(SemSearch)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-rtti -fvisibility-inlines-hidden")

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)

add_library(entry SHARED embedding_napi.cpp)

# MNN static lib (contains core + cpu backend + llm/embedding engine)
add_library(mnn STATIC IMPORTED)
set_target_properties(mnn PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libMNN.a)
# whole-archive: MNN backends (e.g. Vulkan) self-register via static initializers
# inside archive members that nothing references; selective linking drops them.
target_link_libraries(entry PUBLIC
    -Wl,--whole-archive
    mnn
    -Wl,--no-whole-archive)

# NAPI + hilog (MNN OHOS logging goes through hilog)
target_link_libraries(entry PUBLIC libace_napi.z.so)
target_link_libraries(entry PUBLIC libhilog_ndk.z.so)
# libdl for MNN Vulkan wrapper (dlopen libvulkan.so at runtime)
target_link_libraries(entry PUBLIC dl)
