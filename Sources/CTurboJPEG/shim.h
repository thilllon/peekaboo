// libjpeg-turbo (TurboJPEG 3 API), built for the deployment target into .deps/ and linked statically (see
// Package.swift). A "file not found" here means it has not been built yet:
#include "../../.deps/libjpeg-turbo/include/turbojpeg.h"  // run `mise run deps`

// tj3Init is a function-like macro in libjpeg-turbo >= 3.1, which Swift cannot import.
static inline tjhandle pb_tj3Init(int initType) { return tj3Init(initType); }
