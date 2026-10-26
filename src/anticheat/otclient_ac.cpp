/*
 * Anti-cheat library of the distribution client (otclient_ac.dll).
 * User mode only, no driver. Loaded by otclient.exe, which verifies its SHA-256
 * against the signed manifest before loading and sends otac_scan findings in
 * the heartbeat (extended opcode 125).
 *
 * Telemetry only: it never blocks anything, it only reports. Each finding is
 * "<kind>:<detail>", detail limited to [A-Za-z0-9._-] and 64 chars.
 *   proc:<exe>   known cheat/bot/debugger running
 *   dbg:local | dbg:remote   debugger attached
 *   mod:<dll>    module loaded from outside Windows/ and client folder
 *   inj:<pct>    share of synthetic keyboard/mouse events while client had focus
 *
 * otac_scan is BLOCKING and relatively expensive (process snapshot,
 * module enumeration). Call it from a worker thread, never from the UI thread.
 */

#ifndef _WIN32
#error "otclient_ac is Windows only"
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <cwctype>
#include <future>
#include <ranges>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace
{
    constexpr int AC_VERSION = 1;
    constexpr size_t MAX_DETAIL = 64;
    constexpr size_t MAX_FINDINGS = 16;
    constexpr unsigned MIN_INPUT_EVENTS = 50;
    constexpr unsigned INJECTED_PERCENT = 20;

    // exact, lowercase executable names
    constexpr std::array<std::wstring_view, 19> KNOWN_PROGRAMS{
        L"cheatengine.exe", L"autohotkey.exe", L"ahk2exe.exe", L"x64dbg.exe",
        L"x32dbg.exe", L"ollydbg.exe", L"ida.exe", L"ida64.exe",
        L"windbg.exe", L"processhacker.exe", L"systeminformer.exe",
        L"httpdebugger.exe", L"wpe.exe", L"xenobot.exe", L"windbot.exe",
        L"magebot.exe", L"elfbot.exe", L"blackd.exe", L"rifbot.exe"
    };

    std::wstring lower(std::wstring s)
    {
        std::ranges::transform(s, s.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
        return s;
    }

    std::string detail(std::wstring_view text)
    {
        std::string out;
        for (const wchar_t c : text) {
            if (out.size() >= MAX_DETAIL)
                break;
            if ((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') || c == L'.' || c == L'_' || c == L'-')
                out.push_back(static_cast<char>(c));
            else
                out.push_back('_');
        }
        return out.empty() ? "_" : out;
    }

    void scanProcesses(std::vector<std::string>& findings)
    {
        const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE)
            return;
        PROCESSENTRY32W entry{};
        entry.dwSize = sizeof(entry);
        for (BOOL ok = Process32FirstW(snapshot, &entry); ok; ok = Process32NextW(snapshot, &entry)) {
            const auto name = lower(entry.szExeFile);
            // whole-name match: "wpe.exe" must not hit "wpesomething.exe"
            for (const auto& known : KNOWN_PROGRAMS) {
                if (name == known) {
                    findings.push_back("proc:" + detail(name));
                    break;
                }
            }
        }
        CloseHandle(snapshot);
    }

    void scanDebugger(std::vector<std::string>& findings)
    {
        if (IsDebuggerPresent())
            findings.emplace_back("dbg:local");
        BOOL remote = FALSE;
        if (CheckRemoteDebuggerPresent(GetCurrentProcess(), &remote) && remote)
            findings.emplace_back("dbg:remote");
    }

    std::wstring folderOf(const std::wstring& path)
    {
        const auto slash = path.find_last_of(L"\\/");
        return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash + 1);
    }

    void scanModules(std::vector<std::string>& findings)
    {
        std::array<wchar_t, MAX_PATH> buffer{};
        GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        const auto clientFolder = lower(folderOf(buffer.data()));
        GetWindowsDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
        auto windowsFolder = lower(buffer.data());
        if (!windowsFolder.ends_with(L'\\'))
            windowsFolder.push_back(L'\\');

        // first call only asks for the size
        DWORD needed = 0;
        K32EnumProcessModules(GetCurrentProcess(), nullptr, 0, &needed);
        if (needed == 0)
            return;
        std::vector<HMODULE> modules(needed / sizeof(HMODULE));
        if (!K32EnumProcessModules(GetCurrentProcess(), modules.data(),
                                   static_cast<DWORD>(modules.size() * sizeof(HMODULE)), &needed))
            return;
        modules.resize(needed / sizeof(HMODULE));

        for (const HMODULE module : modules) {
            if (K32GetModuleFileNameExW(GetCurrentProcess(), module, buffer.data(),
                                        static_cast<DWORD>(buffer.size())) == 0)
                continue;
            const auto path = lower(buffer.data());
            if (path.starts_with(windowsFolder) || path.starts_with(clientFolder))
                continue;
            const auto slash = path.find_last_of(L"\\/");
            findings.push_back("mod:" + detail(slash == std::wstring::npos ? path : path.substr(slash + 1)));
        }
    }

    // ---- input hooks ----
    std::atomic<unsigned> g_inputTotal{ 0 };
    std::atomic<unsigned> g_inputInjected{ 0 };
    std::atomic<bool> g_hooksStarted{ false };
    std::atomic<bool> g_hooksStop{ false };
    std::thread g_hookThread;
    DWORD g_hookThreadId = 0; // target of the WM_QUIT posted by otac_shutdown
    std::atomic<HWND> g_clientHwnd{ nullptr };

    bool clientHasFocus()
    {
        // the client's own window, not any window of this process (console, dialogs)
        const HWND client = g_clientHwnd.load();
        if (client == nullptr)
            return false;
        return GetForegroundWindow() == client;
    }

    LRESULT CALLBACK keyboardHook(int code, WPARAM wParam, LPARAM lParam)
    {
        if (code == HC_ACTION && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) && clientHasFocus()) {
            ++g_inputTotal;
            if (reinterpret_cast<const KBDLLHOOKSTRUCT*>(lParam)->flags & LLKHF_INJECTED)
                ++g_inputInjected;
        }
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    LRESULT CALLBACK mouseHook(int code, WPARAM wParam, LPARAM lParam)
    {
        if (code == HC_ACTION && wParam != WM_MOUSEMOVE && clientHasFocus()) {
            ++g_inputTotal;
            if (reinterpret_cast<const MSLLHOOKSTRUCT*>(lParam)->flags & LLMHF_INJECTED)
                ++g_inputInjected;
        }
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    void hookThreadProc(std::promise<DWORD>& ready)
    {
        // the module that owns the hook procedures, whatever the DLL is named
        HMODULE self = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                           reinterpret_cast<LPCWSTR>(&keyboardHook), &self);

        // create this thread's message queue before announcing it: a WM_QUIT posted by otac_shutdown is never lost
        MSG peek;
        PeekMessageW(&peek, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
        ready.set_value(GetCurrentThreadId());

        const HHOOK keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHook, self, 0);
        const HHOOK mouse = SetWindowsHookExW(WH_MOUSE_LL, mouseHook, self, 0);

        MSG msg;
        while (!g_hooksStop.load() && GetMessageW(&msg, nullptr, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        if (keyboard) UnhookWindowsHookEx(keyboard);
        if (mouse)    UnhookWindowsHookEx(mouse);
    }

    void startInputHooks(HWND client)
    {
        g_clientHwnd.store(client);
        if (g_hooksStarted.exchange(true))
            return;
        g_hooksStop.store(false);
        std::promise<DWORD> ready;
        auto threadId = ready.get_future();
        g_hookThread = std::thread(hookThreadProc, std::ref(ready));
        g_hookThreadId = threadId.get();
    }

    void scanInput(std::vector<std::string>& findings)
    {
        const unsigned total = g_inputTotal.exchange(0);
        const unsigned injected = g_inputInjected.exchange(0);
        if (total >= MIN_INPUT_EVENTS && injected * 100 >= INJECTED_PERCENT * total)
            findings.push_back("inj:" + std::to_string(injected * 100 / total));
    }
} // namespace

extern "C" __declspec(dllexport) int otac_version() { return AC_VERSION; }

// Starts the input hooks (on a thread of their own) for the client's main window.
extern "C" __declspec(dllexport) void otac_init(void* clientHwnd)
{
    startInputHooks(static_cast<HWND>(clientHwnd));
}

// Stops the hook thread and waits for it. Call it before FreeLibrary.
extern "C" __declspec(dllexport) void otac_shutdown()
{
    if (!g_hooksStarted.exchange(false))
        return;
    g_hooksStop.store(true);
    if (g_hookThreadId != 0)
        PostThreadMessageW(g_hookThreadId, WM_QUIT, 0, 0);
    if (g_hookThread.joinable())
        g_hookThread.join();
    g_hookThreadId = 0;
}

// Roda as varreduras. BLOQUEANTE — chame de uma worker thread.
extern "C" __declspec(dllexport) int otac_scan(char* out, int size)
{
    if (!out || size < 1)
        return -1;
    std::vector<std::string> findings;
    scanProcesses(findings);
    scanDebugger(findings);
    scanModules(findings);
    scanInput(findings);

    std::ranges::sort(findings);
    findings.erase(std::unique(findings.begin(), findings.end()), findings.end());

    std::string text;
    for (size_t i = 0; i < findings.size() && i < MAX_FINDINGS; ++i) {
        const std::string piece = (text.empty() ? "" : ",") + findings[i];
        if (text.size() + piece.size() + 1 > static_cast<size_t>(size))
            break;
        text += piece;
    }
    std::memcpy(out, text.c_str(), text.size() + 1);
    return static_cast<int>(text.size());
}
