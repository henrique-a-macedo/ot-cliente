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

#include "framework/net/inputmessage.h"
#include "game.h"
#include "protocolgame.h"
#include "anticheat/anticheat.h"
#include "framework/core/asyncdispatcher.h"
#include "framework/core/eventdispatcher.h"
#ifdef WIN32
#include "framework/platform/win32window.h"
#endif

#include <openssl/hmac.h>
#include <openssl/sha.h>

void ProtocolGame::login(const std::string_view accountName, const std::string_view accountPassword, const std::string_view host, uint16_t port,
                         const std::string_view characterName, const std::string_view authenticatorToken, const std::string_view sessionKey)
{
    m_accountName = accountName;
    m_accountPassword = accountPassword;
    m_authenticatorToken = authenticatorToken;
    m_sessionKey = sessionKey;
    m_characterName = characterName;

#ifndef __EMSCRIPTEN__
    connect(host, port);
#else
    if (port == 7172)
        port = 443;
    connect(host, port, true);
#endif
}

void ProtocolGame::onConnect()
{
    stopAnticheat(); // new session: no timer left over from the previous one
    m_firstRecv = true;
    Protocol::onConnect();

    m_localPlayer = g_game.getLocalPlayer();

    if (g_game.getFeature(Otc::GameProtocolChecksum))
        enableChecksum();

    if (!g_game.getFeature(Otc::GameChallengeOnLogin))
        sendLoginPacket(0, 0);

    recv();
}

void ProtocolGame::onRecv(const InputMessagePtr& inputMessage)
{
    m_recivedPackeds += 1;
    m_recivedPackedsSize += inputMessage->getMessageSize();

    if (m_firstRecv) {
        m_firstRecv = false;

        if (g_game.getClientVersion() >= 1405) {
            inputMessage->getU8(); // padding
        } else if (g_game.getFeature(Otc::GameMessageSizeCheck)) {
            const int size = inputMessage->getU16();
            if (size != inputMessage->getUnreadSize()) {
                g_logger.traceError("invalid message size");
                return;
            }
        }
    }

    parseMessage(inputMessage);
    recv();
}

void ProtocolGame::onError(const std::error_code& error)
{
    stopAnticheat();
    g_game.processConnectionError(error);
    disconnect();
}

void ProtocolGame::startAnticheat(uint32_t intervalSeconds)
{
    stopAnticheat(); // idempotente
    if (intervalSeconds == 0) {
        g_logger.info("[anticheat] turned off by the server (cfg;0)");
        return;
    }
    if (m_sessionKey.empty()) {
        g_logger.warning("[anticheat] cfg without a session key; ignored");
        return;
    }

#ifdef WIN32
    void* window = static_cast<WIN32Window&>(g_window).getWindowHandle();
#else
    void* window = nullptr;
#endif
    if (!Anticheat::init(window)) {
        // keeps going: the heartbeat then reports the load failure ("dll:missing" / "dll:hash") as its finding
        g_logger.warning("[anticheat] library unavailable ({})", Anticheat::loadFailure());
    }

    // an hour at most: keeps the delay in milliseconds inside an int
    m_anticheatInterval = std::min<uint32_t>(intervalSeconds, 3600);
    m_anticheatSeq = 0;
    g_logger.info("[anticheat] heartbeat every {}s", m_anticheatInterval);
    scheduleAnticheatBeat();
}

void ProtocolGame::stopAnticheat()
{
    if (m_anticheatBeatEvent) {
        m_anticheatBeatEvent->cancel();
        m_anticheatBeatEvent = nullptr;
    }
    // a scan still running on a worker belongs to the old session: its result is dropped
    ++m_anticheatGeneration;
    const uint32_t was = m_anticheatInterval;
    m_anticheatInterval = 0;
    m_anticheatSeq = 0;
    if (was > 0)
        Anticheat::shutdown(); // waits for a scan in progress (Anticheat serializes its calls)
}

void ProtocolGame::scheduleAnticheatBeat()
{
    if (m_anticheatInterval == 0)
        return;

    m_anticheatBeatEvent = g_dispatcher.scheduleEvent(
        [self = std::weak_ptr(static_self_cast<ProtocolGame>())] {
            if (const auto protocol = self.lock())
                protocol->dispatchAnticheatScan();
        },
        static_cast<int>(m_anticheatInterval) * 1000);
}

void ProtocolGame::dispatchAnticheatScan()
{
    if (m_anticheatInterval == 0)
        return;

    // the scan blocks (process snapshot, module list): run it on a worker, send from the main thread
    g_asyncDispatcher->detach_task([self = std::weak_ptr(static_self_cast<ProtocolGame>()), generation = m_anticheatGeneration] {
        std::string findings = Anticheat::scan();
        g_dispatcher.addEvent([self, generation, findings = std::move(findings)] {
            const auto protocol = self.lock();
            if (!protocol || protocol->m_anticheatGeneration != generation || protocol->m_anticheatInterval == 0)
                return;
            protocol->sendAnticheatHeartbeat(findings);
            protocol->scheduleAnticheatBeat();
        });
    });
}

std::string ProtocolGame::computeAnticheatMac(uint32_t seq, const std::string& findings) const
{
    const std::string payload = "hb;" + std::to_string(seq) + ";" + findings;

    unsigned char digest[SHA256_DIGEST_LENGTH];
    const std::string seed = "ot-anticheat-1|" + m_sessionKey;
    SHA256(reinterpret_cast<const unsigned char*>(seed.data()), seed.size(), digest);

    unsigned char mac[SHA256_DIGEST_LENGTH];
    unsigned int macLen = 0;
    HMAC(EVP_sha256(),
         digest, SHA256_DIGEST_LENGTH,
         reinterpret_cast<const unsigned char*>(payload.data()), payload.size(),
         mac, &macLen);

    static constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(macLen * 2);
    for (unsigned int i = 0; i < macLen; ++i) {
        out.push_back(hex[mac[i] >> 4]);
        out.push_back(hex[mac[i] & 0xF]);
    }
    return out;
}
