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

#include "distribution.h"

#ifdef OTC_DISTRIBUTION

#ifndef _WIN32
#error "the distribution build (OPTIONS_DISTRIBUTION) is Windows only"
#endif

#include "logger.h"
#include "resourcemanager.h"
#include "framework/util/crypt.h"

#include <physfs.h>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <vector>

#include <windows.h>

namespace
{
    // must match FORMATO in arch/deploy/launcher/manifest.py and launcher/app/src-tauri/src/manifest.rs
    constexpr int DIST_MANIFEST_FORMAT = 1;

    // package -> virtual mount points, in mount order (each mount goes in front, so the last one wins). Mirrors
    // the development layout: the work dir at "/", then data/ and modules/ also at "/" (init.lua), with things
    // split out of data so a map change does not re-download 100+ MB of sprites.
    struct DistMount
    {
        const char* package;
        const char* mountPoint;
    };
    constexpr std::array DIST_MOUNTS{
        DistMount{ "base.otpkg", "/" },
        DistMount{ "data.otpkg", "/" },
        DistMount{ "data.otpkg", "/data" },
        DistMount{ "things.otpkg", "/things" },
        DistMount{ "things.otpkg", "/data/things" },
        DistMount{ "modules.otpkg", "/" },
        DistMount{ "modules.otpkg", "/modules" },
    };

    // what may come from the user write dir (settings, minimap cache, logs); never code, shaders or assets
    constexpr std::array<std::string_view, 5> DIST_WRITE_DIR_EXTENSIONS{ ".otml", ".otmm", ".json", ".txt", ".log" };

    // the mount names (PHYSFS_getRealDir) of the verified packages
    std::set<std::string> g_distTrusted;

    // A package opened without write/delete sharing for the whole session: once hashed, nobody can swap it.
    struct DistLockedFile
    {
        HANDLE handle = INVALID_HANDLE_VALUE;
        uint64_t size = 0;
    };

    struct DistIoState
    {
        std::shared_ptr<DistLockedFile> file;
        uint64_t pos = 0;
    };

    PHYSFS_Io* distCreateIo(std::shared_ptr<DistLockedFile> file);

    PHYSFS_sint64 distIoRead(PHYSFS_Io* io, void* buffer, PHYSFS_uint64 len)
    {
        auto* state = static_cast<DistIoState*>(io->opaque);
        if (state->pos >= state->file->size)
            return 0;
        len = std::min<PHYSFS_uint64>(len, state->file->size - state->pos);

        uint64_t done = 0;
        while (done < len) {
            const auto chunk = static_cast<DWORD>(std::min<uint64_t>(len - done, 1u << 30));
            const uint64_t offset = state->pos + done;
            OVERLAPPED overlapped{};
            overlapped.Offset = static_cast<DWORD>(offset);
            overlapped.OffsetHigh = static_cast<DWORD>(offset >> 32);
            DWORD read = 0;
            if (!ReadFile(state->file->handle, static_cast<char*>(buffer) + done, chunk, &read, &overlapped)) {
                if (done == 0) {
                    PHYSFS_setErrorCode(PHYSFS_ERR_IO);
                    return -1;
                }
                break;
            }
            if (read == 0)
                break;
            done += read;
        }
        state->pos += done;
        return static_cast<PHYSFS_sint64>(done);
    }

    PHYSFS_sint64 distIoWrite(PHYSFS_Io*, const void*, PHYSFS_uint64)
    {
        PHYSFS_setErrorCode(PHYSFS_ERR_READ_ONLY);
        return -1;
    }

    int distIoSeek(PHYSFS_Io* io, PHYSFS_uint64 offset)
    {
        auto* state = static_cast<DistIoState*>(io->opaque);
        if (offset > state->file->size) {
            PHYSFS_setErrorCode(PHYSFS_ERR_PAST_EOF);
            return 0;
        }
        state->pos = offset;
        return 1;
    }

    PHYSFS_sint64 distIoTell(PHYSFS_Io* io) { return static_cast<PHYSFS_sint64>(static_cast<DistIoState*>(io->opaque)->pos); }

    PHYSFS_sint64 distIoLength(PHYSFS_Io* io) { return static_cast<PHYSFS_sint64>(static_cast<DistIoState*>(io->opaque)->file->size); }

    PHYSFS_Io* distIoDuplicate(PHYSFS_Io* io) { return distCreateIo(static_cast<DistIoState*>(io->opaque)->file); }

    int distIoFlush(PHYSFS_Io*) { return 1; }

    void distIoDestroy(PHYSFS_Io* io)
    {
        delete static_cast<DistIoState*>(io->opaque);
        delete io;
    }

    PHYSFS_Io* distCreateIo(std::shared_ptr<DistLockedFile> file)
    {
        auto* io = new PHYSFS_Io{};
        io->version = 0;
        io->opaque = new DistIoState{ std::move(file), 0 };
        io->read = distIoRead;
        io->write = distIoWrite;
        io->seek = distIoSeek;
        io->tell = distIoTell;
        io->length = distIoLength;
        io->duplicate = distIoDuplicate;
        io->flush = distIoFlush;
        io->destroy = distIoDestroy;
        return io;
    }

    std::shared_ptr<DistLockedFile> distOpenLocked(const std::filesystem::path& path)
    {
        // FILE_SHARE_READ only: while the client runs, the package cannot be written, renamed or deleted
        const HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                                          FILE_ATTRIBUTE_NORMAL, nullptr);
        if (handle == INVALID_HANDLE_VALUE)
            return nullptr;
        LARGE_INTEGER size{};
        if (!GetFileSizeEx(handle, &size)) {
            CloseHandle(handle);
            return nullptr;
        }
        // never closed: the mounts live until the process exits
        return std::make_shared<DistLockedFile>(DistLockedFile{ handle, static_cast<uint64_t>(size.QuadPart) });
    }

    std::string distSha256(const DistLockedFile& file)
    {
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        if (!ctx || EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) != 1) {
            EVP_MD_CTX_free(ctx);
            return {};
        }
        std::vector<char> buffer(1 << 20);
        uint64_t offset = 0;
        bool ok = true;
        while (offset < file.size) {
            OVERLAPPED overlapped{};
            overlapped.Offset = static_cast<DWORD>(offset);
            overlapped.OffsetHigh = static_cast<DWORD>(offset >> 32);
            DWORD read = 0;
            if (!ReadFile(file.handle, buffer.data(), static_cast<DWORD>(buffer.size()), &read, &overlapped) || read == 0) {
                ok = false;
                break;
            }
            EVP_DigestUpdate(ctx, buffer.data(), read);
            offset += read;
        }
        std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
        unsigned int digestSize = 0;
        ok = ok && EVP_DigestFinal_ex(ctx, digest.data(), &digestSize) == 1;
        EVP_MD_CTX_free(ctx);
        if (!ok)
            return {};

        static constexpr char hex[] = "0123456789abcdef";
        std::string out;
        for (unsigned int i = 0; i < digestSize; ++i) {
            out.push_back(hex[digest[i] >> 4]);
            out.push_back(hex[digest[i] & 0xF]);
        }
        return out;
    }

    bool distVerifySignature(const std::string& message, const std::string& signatureBase64)
    {
        const std::string key = g_crypt.base64Decode(OTC_MANIFEST_PUBLIC_KEY);
        std::string trimmed = signatureBase64;
        stdext::trim(trimmed);
        const std::string signature = g_crypt.base64Decode(trimmed);
        if (key.size() != 32 || signature.size() != 64)
            return false;

        EVP_PKEY* pkey = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, nullptr,
                                                     reinterpret_cast<const unsigned char*>(key.data()), key.size());
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        const bool ok = pkey && ctx
            && EVP_DigestVerifyInit(ctx, nullptr, nullptr, nullptr, pkey) == 1
            && EVP_DigestVerify(ctx, reinterpret_cast<const unsigned char*>(signature.data()), signature.size(),
                                reinterpret_cast<const unsigned char*>(message.data()), message.size()) == 1;
        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        return ok;
    }

    bool distReadWholeFile(const std::filesystem::path& path, std::string& out)
    {
        std::ifstream file(path, std::ios::binary);
        if (!file.is_open())
            return false;
        std::ostringstream buffer;
        buffer << file.rdbuf();
        out = buffer.str();
        return true;
    }
}

bool distribution::mountVerifiedPackages(const std::string& workDir)
{
    const std::filesystem::path dir(workDir);

    std::string manifestText, signature;
    if (!distReadWholeFile(dir / "manifest.json", manifestText) || !distReadWholeFile(dir / "manifest.sig", signature)) {
        g_logger.error("distribution: manifest.json/manifest.sig missing in '{}'", workDir);
        return false;
    }
    if (!distVerifySignature(manifestText, signature)) {
        g_logger.error("distribution: manifest signature does not match");
        return false;
    }

    // package name -> expected (size, sha256), only for the top-level *.otpkg entries of the signed manifest
    std::map<std::string, std::pair<uint64_t, std::string>> expected;
    try {
        const auto manifest = nlohmann::json::parse(manifestText);
        if (manifest.at("formato").get<int>() != DIST_MANIFEST_FORMAT) {
            g_logger.error("distribution: manifest format {} not supported", manifest.at("formato").dump());
            return false;
        }
        for (const auto& entry : manifest.at("arquivos")) {
            const auto path = entry.at("caminho").get<std::string>();
            if (path.ends_with(".otpkg") && path.find('/') == std::string::npos)
                expected[path] = { entry.at("tamanho").get<uint64_t>(), entry.at("sha256").get<std::string>() };
        }
    } catch (const std::exception& e) {
        g_logger.error("distribution: invalid manifest: {}", e.what());
        return false;
    }

    std::map<std::string, std::shared_ptr<DistLockedFile>> packages;
    for (const auto& mount : DIST_MOUNTS) {
        if (packages.contains(mount.package))
            continue;
        const auto it = expected.find(mount.package);
        if (it == expected.end()) {
            g_logger.error("distribution: {} is not in the manifest", mount.package);
            return false;
        }
        auto file = distOpenLocked(dir / mount.package);
        if (!file) {
            g_logger.error("distribution: unable to open {}", mount.package);
            return false;
        }
        if (file->size != it->second.first || distSha256(*file) != it->second.second) {
            g_logger.error("distribution: {} does not match the manifest", mount.package);
            return false;
        }
        packages[mount.package] = std::move(file);
    }

    // nothing loose next to the executable is visible from now on
    PHYSFS_unmount(workDir.c_str());

    for (const auto& mount : DIST_MOUNTS) {
        const std::string name = fmt::format("{}@{}", mount.package, mount.mountPoint);
        PHYSFS_Io* io = distCreateIo(packages[mount.package]);
        if (!PHYSFS_mountIo(io, name.c_str(), mount.mountPoint, 0)) {
            g_logger.error("distribution: unable to mount {}: {}", name, PHYSFS_getErrorByCode(PHYSFS_getLastErrorCode()));
            io->destroy(io);
            return false;
        }
        g_distTrusted.insert(name);
    }

    if (!canRead("/init.lua") || !PHYSFS_exists("init.lua")) {
        g_logger.error("distribution: init.lua is not in the packages");
        return false;
    }
    return true;
}

bool distribution::canRead(const std::string& virtualPath)
{
    const char* realDir = PHYSFS_getRealDir(virtualPath.c_str());
    if (!realDir)
        return true; // does not exist: let the caller fail with its usual error
    if (g_distTrusted.contains(realDir))
        return true;

    const std::string writeDir = g_resources.getWriteDir();
    if (writeDir.empty() || writeDir != realDir)
        return false;
    std::string extension = std::filesystem::path(virtualPath).extension().string();
    stdext::tolower(extension);
    return std::ranges::find(DIST_WRITE_DIR_EXTENSIONS, extension) != DIST_WRITE_DIR_EXTENSIONS.end();
}

#else

bool distribution::mountVerifiedPackages(const std::string&) { return false; }

bool distribution::canRead(const std::string&) { return true; }

#endif
