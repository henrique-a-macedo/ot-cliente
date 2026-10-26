#pragma once

#include <functional>
#include <string>

// The client's side of the launcher (arch/.claude/ref/workspace/contratos-cross-repo.md, section 9): the launcher
// opens the client with a one-use ticket (OTC_LAUNCH_TICKET) and the name of a pipe of its own (OTC_LAUNCHER_PIPE).
// Back on the login screen (logout, connection lost), the client asks the launcher for a new ticket through that pipe;
// the launcher trades its session for one (type "renew"), so the password is never asked again.
class LauncherBridge
{
public:
    // the ticket the launcher opened the client with, once; the variable is cleared so no child process inherits it
    std::string takeTicket();

    // the launcher that opened this client is listening (Windows only)
    bool canRequestTicket() const;

    // asks the launcher for a new ticket on a worker thread; the callback runs on the main thread with the ticket, or
    // with an empty ticket and the reason
    void requestTicket(const std::function<void(const std::string& ticket, const std::string& error)>& callback);

private:
    bool m_ticketTaken{ false };
};

extern LauncherBridge g_launcher;
