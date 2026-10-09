// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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