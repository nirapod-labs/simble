# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

add_library(simble_protocol_c src/simble_protocol.c)
target_include_directories(simble_protocol_c PUBLIC include)

add_executable(protocol_test tests/protocol_test.c)
target_link_libraries(protocol_test PRIVATE simble_protocol_c)
add_test(NAME protocol_test COMMAND protocol_test)
