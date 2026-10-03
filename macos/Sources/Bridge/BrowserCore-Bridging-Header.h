//
//  BrowserCore-Bridging-Header.h
//  Whatever
//
//  Exposes the Nim core's C ABI to Swift. The declarations live in the Nim
//  side's own header so there is exactly one definition of the ABI.
//
//  Only the WhateverStore XPC service links the core: boogie holds an
//  exclusive lock on each store path, so exactly one process may open them,
//  and the app reaches everything through XPC instead. The app target
//  therefore does not compile this header.
//
//  Build `../core/build/libbrowsercore.a` first (`make -C ../core build`);
//  the macOS Makefile does this automatically.
//

#import "../../../core/include/browsercore.h"