cmake_minimum_required(VERSION 3.28...3.30)

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/common/bootstrap.cmake" NO_POLICY_SCOPE)

project(obs-studio VERSION ${OBS_VERSION_CANONICAL})

if(CMAKE_HOST_SYSTEM_NAME MATCHES "Windows")
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/windows/architecture.cmake")
  if(NOT OBS_PARENT_ARCHITECTURE STREQUAL CMAKE_VS_PLATFORM_NAME)
    return()
  endif()
endif()

include(compilerconfig)
include(defaults)
include(helpers)

option(ENABLE_FRONTEND "Enable building with UI (requires Qt)" ON)
option(ENABLE_SCRIPTING "Enable scripting support" ON)
option(ENABLE_HEVC "Enable HEVC encoders" ON)
option(ENABLE_PORTABLE_CONFIG "Enable support for portable config file location" OFF)
option(ENABLE_DUAL_CAPTURE_TESTS "Build focused Dual Capture regression tests" OFF)
option(ENABLE_DUAL_CAPTURE_TEST_HOOKS "Enable Debug-only Dual Capture failure injection" OFF)

add_subdirectory(libobs)
if(OS_WINDOWS)
  add_subdirectory(libobs-d3d11)
  add_subdirectory(libobs-winrt)
endif()
add_subdirectory(libobs-opengl)
if(OS_MACOS)
  add_subdirectory(libobs-metal)
endif()
add_subdirectory(plugins)

add_subdirectory(test/test-input)
if(ENABLE_DUAL_CAPTURE_TESTS)
  enable_testing()
  add_subdirectory(test/dual-capture)
endif()

add_subdirectory(frontend)

message_configuration()
