// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Darwin
import SimBLECTLKit

let result = SimBLECTL.handle(arguments: CommandLine.arguments)
print(result.output)
exit(result.exitCode)
