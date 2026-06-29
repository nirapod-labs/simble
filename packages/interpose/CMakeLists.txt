# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

if(SIMBLE_SIM_PLATFORM STREQUAL "watchos")
  set(SIMBLE_INTERPOSE_OUTPUT "simble-interpose-watchos")
else()
  set(SIMBLE_INTERPOSE_OUTPUT "simble-interpose")
endif()

set(SIMBLE_FRAMEWORKS "-framework CoreBluetooth" "-framework Foundation")

# The interposer core: the central and peripheral swizzles, the shadow registry, and the loopback
# transport. No load constructor here; the dylib and the host harness add their own entry point, so
# both reuse this. The .m files use ARC.
add_library(interpose_core STATIC
  src/hooks/central_hooks.m
  src/hooks/peripheral_hooks.m
  src/registry/shadow.m
  src/transport/client.c
)
target_include_directories(interpose_core PUBLIC include src/transport src/registry src/hooks)
target_compile_options(interpose_core PRIVATE $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)
target_link_libraries(interpose_core PUBLIC simble_protocol_c ${SIMBLE_FRAMEWORKS})

if(SIMBLE_SIM_SLICE)
  # The injectable dylib: the core plus the dyld load constructor. Each simulator platform gets
  # its own name; ios keeps the canonical simble-interpose, so the helper and scripts that load
  # it by that name need no change.
  add_library(simble_interpose SHARED src/entry.c)
  target_include_directories(simble_interpose PRIVATE include)
  set_target_properties(
    simble_interpose
    PROPERTIES
      PREFIX ""
      OUTPUT_NAME "${SIMBLE_INTERPOSE_OUTPUT}"
      SUFFIX ".dylib"
  )
  target_link_libraries(simble_interpose PRIVATE interpose_core ${SIMBLE_FRAMEWORKS})
else()
  # The swizzle smoke test: install and uninstall on the host, where the CB classes exist.
  add_executable(hook_smoke tests/hook_smoke.c)
  target_link_libraries(hook_smoke PRIVATE interpose_core ${SIMBLE_FRAMEWORKS})
  add_test(NAME hook_smoke COMMAND hook_smoke)

  # The shadow registry unit test: mint, look up, fail closed.
  add_executable(shadow_registry_test tests/shadow_registry_test.m)
  target_compile_options(shadow_registry_test PRIVATE -fobjc-arc)
  target_link_libraries(shadow_registry_test PRIVATE interpose_core ${SIMBLE_FRAMEWORKS})
  add_test(NAME shadow_registry COMMAND shadow_registry_test)

  # The passthrough invariant: a non-managed CBCentralManager method is unaffected by the
  # installed swizzle. No helper, so it runs as a plain ctest.
  add_executable(passthrough_test tests/passthrough_test.m)
  target_compile_options(passthrough_test PRIVATE -fobjc-arc)
  target_link_libraries(passthrough_test PRIVATE interpose_core ${SIMBLE_FRAMEWORKS})
  add_test(NAME passthrough COMMAND passthrough_test)

  # The transport round-trip: the client encodes a request and decodes a response and an event
  # against an in-test loopback echo, no radio and no helper.
  add_executable(client_roundtrip tests/client_roundtrip.c)
  target_link_libraries(client_roundtrip PRIVATE interpose_core ${SIMBLE_FRAMEWORKS})
  add_test(NAME client_roundtrip COMMAND client_roundtrip)
endif()
