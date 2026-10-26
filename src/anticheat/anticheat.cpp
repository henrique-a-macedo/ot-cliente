#include "anticheat.h"

#ifdef _WIN32

#include "framework/core/distribution.h"
#include "framework/core/logger.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <filesystem>
#include <mutex>

namespace
{
    constexpr int AC_VERSION = 1;
    constexpr const char* AC_DLL = "otclient_ac.dll";

    using VersionFn = int (*)();
    using InitFn = void (*)(void*);
    using ShutdownFn = void (*)();
    using ScanFn = int (*)(char*, int);

    // init/shutdown run on the main thread and scan on a worker: one lock serializes them, so the library is
    // never unloaded while a scan is inside it (shutdown waits for the scan, at most one scan long)
    std::mutex g_mutex;
    HMODULE g_dll = nullptr;
    InitFn g_init = nullptr;
    ShutdownFn g_shutdown = nullptr;
    ScanFn g_scan = nullptr;
    std::string g_loadFailure;

    void unload()
    {
        if (g_dll)
            FreeLibrary(g_dll);
        g_dll = nullptr;
        g_init = nullptr;
        g_shutdown = nullptr;
        g_scan = nullptr;
    }
}

namespace Anticheat
{
    bool init(void* nativeWindowHandle)
    {
        std::scoped_lock lock(g_mutex);
        if (g_dll)
            return true;

        // distribution build: full path of the copy checked against the signed manifest and locked against writes
        const std::string path = distribution::lockVerifiedFile(AC_DLL);
        if (path.empty()) {
            g_loadFailure = "dll:hash";
            return false;
        }

        g_dll = LoadLibraryW(std::filesystem::path(path).c_str());
        if (!g_dll) {
            g_loadFailure = "dll:missing";
            g_logger.warning("[anticheat] {} failed to load (error {})", AC_DLL, GetLastError());
            return false;
        }

        const auto version = reinterpret_cast<VersionFn>(GetProcAddress(g_dll, "otac_version"));
        g_init = reinterpret_cast<InitFn>(GetProcAddress(g_dll, "otac_init"));
        g_shutdown = reinterpret_cast<ShutdownFn>(GetProcAddress(g_dll, "otac_shutdown"));
        g_scan = reinterpret_cast<ScanFn>(GetProcAddress(g_dll, "otac_scan"));
        if (!version || !g_init || !g_shutdown || !g_scan || version() != AC_VERSION) {
            g_loadFailure = "dll:hash"; // missing symbols or another version: not the library we shipped
            g_logger.error("[anticheat] {} lacks the otac_* symbols or is another version", AC_DLL);
            unload();
            return false;
        }

        g_init(nativeWindowHandle);
        g_loadFailure.clear();
        return true;
    }

    std::string scan()
    {
        std::scoped_lock lock(g_mutex);
        if (!g_scan)
            return g_loadFailure;
        // the whole "hb;<seq>;<findings>;<mac>" must fit the server's Anticheat.MAX_MESSAGE (1024)
        char buffer[900] = {};
        const int size = g_scan(buffer, sizeof(buffer));
        if (size <= 0)
            return {};
        return std::string(buffer, static_cast<size_t>(size));
    }

    void shutdown()
    {
        std::scoped_lock lock(g_mutex);
        if (g_shutdown)
            g_shutdown();
        unload();
        // g_loadFailure stays: the next init() reports it again if it still fails
    }

    bool isLoaded()
    {
        std::scoped_lock lock(g_mutex);
        return g_dll != nullptr;
    }

    std::string loadFailure()
    {
        std::scoped_lock lock(g_mutex);
        return g_loadFailure;
    }
}

#else

namespace Anticheat
{
    bool init(void*) { return false; }
    std::string scan() { return {}; }
    void shutdown() {}
    bool isLoaded() { return false; }
    std::string loadFailure() { return {}; }
}

#endif
