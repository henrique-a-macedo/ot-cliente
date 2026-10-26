/*
 * Client side of the anti-cheat library (otclient_ac.dll, see otclient_ac.cpp).
 * Windows only. On other platforms every function is a no-op, so the protocol code can call it unconditionally.
 *
 *   init(hwnd)     loads the library (distribution build: only the copy that matches the signed manifest, locked
 *                  against writes) and calls otac_init with the client window
 *   scan()         calls otac_scan, BLOCKING: call it from a worker thread. Returns "kind:detail,..." or "";
 *                  when the library did not load, returns the load failure ("dll:missing" / "dll:hash")
 *   shutdown()     calls otac_shutdown and unloads the library; idempotent
 *
 * The calls are serialized: shutdown waits for a scan in progress.
 */
#pragma once

#include <string>

namespace Anticheat
{
    bool init(void* nativeWindowHandle);
    std::string scan();
    void shutdown();

    bool isLoaded();
    std::string loadFailure();
}
