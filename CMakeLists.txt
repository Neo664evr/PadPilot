cmake_minimum_required(VERSION 3.24)
project(PadPilot VERSION 1.0.0 LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(SDL3 CONFIG REQUIRED)

add_executable(PadPilot WIN32
    src/main.cpp
    src/core.hpp
    src/app.rc
)
target_include_directories(PadPilot PRIVATE src)
target_compile_definitions(PadPilot PRIVATE UNICODE _UNICODE)
target_link_libraries(PadPilot PRIVATE
    SDL3::SDL3
    comctl32 shell32 wtsapi32 winmm
)

if(MINGW)
    target_link_options(PadPilot PRIVATE -municode -static-libgcc -static-libstdc++)
endif()

set_target_properties(PadPilot PROPERTIES OUTPUT_NAME "PadPilot_v1_0")

enable_testing()
add_executable(PadPilotCoreTests src/tests.cpp)
target_include_directories(PadPilotCoreTests PRIVATE src)
add_test(NAME PadPilotCoreTests COMMAND PadPilotCoreTests)
