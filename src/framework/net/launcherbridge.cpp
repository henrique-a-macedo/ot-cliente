#include "launcherbridge.h"

#include <framework/core/asyncdispatcher.h>
#include <framework/core/eventdispatcher.h>

#include <cstdlib>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

LauncherBridge g_launcher;

namespace
{
    constexpr const char* TICKET_VARIABLE = "OTC_LAUNCH_TICKET";
    constexpr const char* PIPE_VARIABLE = "OTC_LAUNCHER_PIPE";
    // the launcher's pipes are \\.\pipe\ot-launcher-<hex>; anything else in the variable is ignored
    constexpr std::string_view PIPE_PREFIX = R"(\\.\pipe\ot-launcher-)";
    constexpr size_t MAX_ANSWER = 512;

    std::string environment(const char* name)
    {
        const char* value = std::getenv(name);
        return value ? value : "";
    }

    std::string pipeName()
    {
        const std::string name = environment(PIPE_VARIABLE);
        if (!name.starts_with(PIPE_PREFIX) || name.size() > PIPE_PREFIX.size() + 64)
            return {};
        return name;
    }

#ifdef _WIN32
    // one request per connection: "ticket\n" -> "ok:<ticket>\n" or "error:<reason>\n"
    std::pair<std::string, std::string> askLauncher(const std::string& name)
    {
        if (!WaitNamedPipeA(name.c_str(), 5000))
            return { {}, "the launcher is not open" };
        const HANDLE pipe = CreateFileA(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe == INVALID_HANDLE_VALUE)
            return { {}, "the launcher is not open" };

        constexpr std::string_view request = "ticket\n";
        DWORD written = 0;
        std::string answer;
        if (WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()), &written, nullptr)) {
            char buffer[128];
            DWORD read = 0;
            while (answer.size() < MAX_ANSWER && answer.find('\n') == std::string::npos &&
                   ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
                answer.append(buffer, read);
            }
        }
        CloseHandle(pipe);

        const auto end = answer.find('\n');
        if (end == std::string::npos)
            return { {}, "no answer from the launcher" };
        answer.resize(end);
        if (answer.starts_with("ok:") && answer.size() > 3)
            return { answer.substr(3), {} };
        if (answer.starts_with("error:"))
            return { {}, answer.substr(6) };
        return { {}, "unexpected answer from the launcher" };
    }
#endif
}

std::string LauncherBridge::takeTicket()
{
    if (m_ticketTaken)
        return {};
    m_ticketTaken = true;
    std::string ticket = environment(TICKET_VARIABLE);
#ifdef _WIN32
    _putenv_s(TICKET_VARIABLE, "");
#endif
    return ticket;
}

bool LauncherBridge::canRequestTicket() const
{
#ifdef _WIN32
    return !pipeName().empty();
#else
    return false;
#endif
}

void LauncherBridge::requestTicket(const std::function<void(const std::string& ticket, const std::string& error)>& callback)
{
#ifdef _WIN32
    const std::string name = pipeName();
    if (name.empty()) {
        g_dispatcher.addEvent([callback] { callback({}, "the client was not opened by the launcher"); });
        return;
    }
    g_asyncDispatcher->detach_task([name, callback] {
        auto [ticket, error] = askLauncher(name);
        g_dispatcher.addEvent([callback, ticket = std::move(ticket), error = std::move(error)] { callback(ticket, error); });
    });
#else
    g_dispatcher.addEvent([callback] { callback({}, "the client was not opened by the launcher"); });
#endif
}
