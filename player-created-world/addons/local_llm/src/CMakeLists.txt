cmake_minimum_required(VERSION 3.20)
project(local_llm_extension LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Configuration options
option(BUILD_SHARED_LIBS "Build as shared library" ON)
option(LLAMA_CUDA "Enable CUDA support" OFF)
option(LLAMA_METAL "Enable Metal support" OFF)
option(LLAMA_VULKAN "Enable Vulkan support" OFF)

# Build llama.cpp first
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)  # Static lib for llama
add_subdirectory(llama.cpp)

# godot-cpp
set(GODOT_CPP_SYSTEM_HEADERS ON CACHE BOOL "" FORCE)
add_subdirectory(godot-cpp)

# Extension sources
set(EXTENSION_SOURCES
    register_types.cpp
    llm_generation_handle.cpp
    llama_cpp_provider.cpp
)

# Create the shared library
add_library(local_llm SHARED ${EXTENSION_SOURCES})

target_include_directories(local_llm PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/include
    ${CMAKE_CURRENT_SOURCE_DIR}/llama.cpp/ggml/include
)

target_link_libraries(local_llm PRIVATE
    godot-cpp
    llama
    ggml
)

# Platform-specific settings
if(WIN32)
    target_link_libraries(local_llm PRIVATE ws2_32)
    set_target_properties(local_llm PROPERTIES
        OUTPUT_NAME "liblocal_llm.windows.$<IF:$<CONFIG:Debug>,editor,template_release>.x86_64"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    )
elseif(APPLE)
    set_target_properties(local_llm PROPERTIES
        OUTPUT_NAME "liblocal_llm.macos.$<IF:$<CONFIG:Debug>,editor,template_release>.universal"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    )
else()
    target_link_libraries(local_llm PRIVATE pthread dl)
    set_target_properties(local_llm PROPERTIES
        OUTPUT_NAME "liblocal_llm.linux.$<IF:$<CONFIG:Debug>,editor,template_release>.x86_64"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../bin"
    )
endif()

# Backend defines for compile-time detection
if(LLAMA_CUDA)
    target_compile_definitions(local_llm PRIVATE GGML_USE_CUDA)
endif()
if(LLAMA_METAL)
    target_compile_definitions(local_llm PRIVATE GGML_USE_METAL)
endif()
if(LLAMA_VULKAN)
    target_compile_definitions(local_llm PRIVATE GGML_USE_VULKAN)
endif()
