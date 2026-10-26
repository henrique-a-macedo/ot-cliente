/*
 * Copyright (c) 2010-2026 OTClient <https://github.com/edubart/otclient>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#pragma once

#include <string>

// Distribution build (OPTIONS_DISTRIBUTION=ON, defines OTC_DISTRIBUTION): the client only runs code that came
// signed through the launcher. The launcher leaves its signed manifest.json/manifest.sig in the work dir; on
// startup the client checks the signature with the embedded ed25519 key (OTC_MANIFEST_PUBLIC_KEY, the same key
// as the launcher), locks each package (*.otpkg) against writes, checks its SHA-256 against the manifest and
// mounts it. The work dir itself is unmounted: loose files next to the executable are never read.
// See arch/.claude/ref/client/distribuicao.md.
namespace distribution
{
    constexpr bool enabled()
    {
#ifdef OTC_DISTRIBUTION
        return true;
#else
        return false;
#endif
    }

    // Verifies manifest + packages in workDir and mounts them; false (with the reason logged) if anything fails.
    bool mountVerifiedPackages(const std::string& workDir);

    // May the file at this virtual path be read? Packages: anything. The user write dir: only data files
    // (settings, minimap cache), never code. Anything else: no.
    bool canRead(const std::string& virtualPath);
}
