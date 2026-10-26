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

#include <atomic>
#include <cstdint>
#include <string>

#include <framework/luaengine/luaobject.h>

class LoginHttp final : public LuaObject
{
public:
    LoginHttp();

    void startHttpLogin(const std::string& host, const std::string& path,
                        uint16_t port, const std::string& email,
                        const std::string& password);

    void Logger(const auto& req, const auto& res);

    std::string getCharacterList();

    std::string getWorldList();

    std::string getSession();

    bool parseJsonResponse(const std::string& body);

    void httpLogin(const std::string& host, const std::string& path,
                   uint16_t port, const std::string& email,
                    const std::string& password, int request_id, bool httpLogin, const std::string& token);

    void cancel();

    // launch ticket from the launcher (OTC_LAUNCH_TICKET): when set, the request is {type: "ticket"} instead of the
    // email/password login (arch/.claude/ref/workspace/contratos-cross-repo.md, section 9)
    void setTicket(const std::string& ticket) { m_ticket = ticket; }

    enum Result : int { Success = 200, Error = -1 };

private:
    struct HttpResponse {
        bool connected{ false };
        int status{ Error };
        std::string reason;
        std::string body;

        explicit operator bool() const { return connected; }
    };

    HttpResponse loginHttpsJson(const std::string& host,
                                const std::string& path, uint16_t port,
                                const std::string& email,
                                const std::string& password,
                                const std::string& token);

    HttpResponse loginHttpJson(const std::string& host,
                               const std::string& path, uint16_t port,
                               const std::string& email,
                               const std::string& password,
                               const std::string& token);

    std::string characters;
    std::string worlds;
    std::string session;
    std::string errorMessage;
    std::string m_ticket;
    std::atomic<bool> cancelled;

    // replaces the login body by the ticket exchange when a ticket was set
    template<typename Json>
    void applyTicket(Json& body) const
    {
        if (!m_ticket.empty())
            body = Json{ {"type", "ticket"}, {"ticket", m_ticket} };
    }
};
