# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

if(SIMBLE_SIM_PLATFORM STREQUAL "watchos")
  set(SIMBLE_INTERPOSE_OUTPUT "simble-interpose-watchos")
else()
  set(SIMBLE_INTERPOSE_OUTPUT "simble-interpose")
endif()

if(SIMBLE_SIM_SLICE)
  add_library(simble_interpose MODULE src/entry.c)
  target_include_directories(simble_interpose PRIVATE include)
  set_target_properties(
    simble_interpose
    PROPERTIES
      PREFIX ""
      OUTPUT_NAME "${SIMBLE_INTERPOSE_OUTPUT}"
  )
else()
  add_executable(hook_smoke tests/hook_smoke.c src/entry.c)
  target_include_directories(hook_smoke PRIVATE include)
  add_test(NAME hook_smoke COMMAND hook_smoke)
endif()
