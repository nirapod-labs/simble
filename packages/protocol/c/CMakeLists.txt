# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

# The C codec: the interposer's half of the wire protocol (see ../SPEC.md).
add_library(simble_protocol_c
  src/simble_protocol.c
  src/simble_framing.c
)
target_include_directories(simble_protocol_c PUBLIC include)

add_executable(protocol_test tests/protocol_test.c)
target_link_libraries(protocol_test PRIVATE simble_protocol_c)
add_test(NAME protocol_test COMMAND protocol_test)
