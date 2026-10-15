# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "gamepads_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "gamepads_windows_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "gamepads_windows_plugin.cpp"
  "gamepads_windows_plugin.h"
  "gamepad.cpp"
  "gamepad.h"
  "utils.cpp"
  "utils.h"
  "gameinput/GameInput.cpp"
  "gameinput/GameInput.h"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/gamepads_windows/gamepads_windows_plugin_c_api.h"
  "gamepads_windows_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# The GameInput runtime the v2 API needs. Windows only ships the v0 runtime,
# so it is bundled next to the exe, where gameinput/GameInput.cpp finds it
# (a newer system-wide install wins). The raw input proxy is launched by it.
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  set(GAMEINPUT_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/gameinput/bin/arm64")
else()
  set(GAMEINPUT_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/gameinput/bin/x64")
endif()
set(gamepads_windows_bundled_libraries
  "${GAMEINPUT_BIN_DIR}/GameInputRedist.dll"
  "${GAMEINPUT_BIN_DIR}/GameInputRawInputProxy.exe"
  PARENT_SCOPE
)
