-- Player report: sends client packet 0xF2 (server ProtocolGame::parseRuleViolationReport -> Player:onReportRuleViolation,
-- written to data/logs/rule_reports.log and shown in the backoffice). No hotkey on purpose; the entry points are the
-- main panel button and "Report" in a player's right-click menu.
-- { text, type, reason } with the server's REPORT_TYPE_* and REPORT_REASON_* (src/enums.h)
local REASONS = {
    { 'Inappropriate name', 0, 0 },
    { 'Advertising in the name', 0, 2 },
    { 'Name against the rules', 0, 4 },
    { 'Insulting statement', 1, 5 },
    { 'Spamming', 1, 6 },
    { 'Advertising', 1, 7 },
    { 'Sharing personal data', 1, 10 },
    { 'Rule violation', 1, 11 },
    { 'Bug abuse', 1, 12 },
    { 'Unofficial software / bot', 2, 13 },
}
local MAX_COMMENT = 1000

local reportWindow = nil
local reportButton = nil

local function hide()
    if reportWindow then
        reportWindow:hide()
    end
end

local function send()
    local name = reportWindow:getChildById('nameEdit'):getText():trim()
    local option = reportWindow:getChildById('reasonBox'):getCurrentOption()
    local comment = reportWindow:getChildById('commentEdit'):getText():sub(1, MAX_COMMENT)
    if name == '' then
        modules.game_textmessage.displayFailureMessage(tr('Type the name of the player to report.'))
        return
    end
    g_game.reportPlayer(option.data[1], option.data[2], name, comment)
    hide()
end

function show(targetName)
    if not g_game.isOnline() then
        return
    end
    reportWindow:getChildById('nameEdit'):setText(targetName or '')
    reportWindow:getChildById('commentEdit'):setText('')
    reportWindow:show()
    reportWindow:raise()
    reportWindow:focus()
end

local function toggle()
    if reportWindow:isVisible() then
        hide()
    else
        show()
    end
end

local function onGameEnd()
    hide()
end

function init()
    g_ui.importStyle('report')
    reportWindow = g_ui.createWidget('ReportWindow', rootWidget)
    reportWindow:hide()
    local box = reportWindow:getChildById('reasonBox')
    for _, reason in ipairs(REASONS) do
        box:addOption(tr(reason[1]), { reason[2], reason[3] })
    end
    reportWindow:getChildById('sendButton').onClick = send
    reportWindow:getChildById('cancelButton').onClick = hide
    reportButton = modules.game_mainpanel.addToggleButton('reportButton', tr('Report a player'),
        '/images/options/button_frags', toggle, false, 10)
    connect(g_game, { onGameEnd = onGameEnd })
end

function terminate()
    disconnect(g_game, { onGameEnd = onGameEnd })
    if reportButton then
        reportButton:destroy()
        reportButton = nil
    end
    if reportWindow then
        reportWindow:destroy()
        reportWindow = nil
    end
end
