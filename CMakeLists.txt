# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

cmake_minimum_required(VERSION 3.24)
project(SimBLE LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

option(SIMBLE_SIM_SLICE "Build a simulator interposer slice" OFF)
set(SIMBLE_SIM_PLATFORM "ios" CACHE STRING "Simulator platform for the slice")

enable_testing()

add_subdirectory(packages/protocol/c)
add_subdirectory(packages/interpose)
