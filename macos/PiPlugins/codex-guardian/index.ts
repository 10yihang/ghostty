// SPDX-License-Identifier: Apache-2.0
import { completeSimple as complete } from "@earendil-works/pi-ai/compat";
import { createGuardianExtension } from "./guardian.mjs";

export default createGuardianExtension({ complete });
