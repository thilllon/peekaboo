// libjpeg-turbo (TurboJPEG 3 API), linked statically from Homebrew's jpeg-turbo
// (`brew install jpeg-turbo`). See Package.swift for the archive path.
#include "/opt/homebrew/opt/jpeg-turbo/include/turbojpeg.h"

// tj3Init is a function-like macro in libjpeg-turbo >= 3.1, which Swift cannot import.
static inline tjhandle pb_tj3Init(int initType) { return tj3Init(initType); }
