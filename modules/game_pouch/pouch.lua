-- Currency pouch (server opcode 124, forgottenserver data/scripts/lib/currency_pouch.lua).
-- A side window like VIP or Battle (docks in the columns, minimizes, locks): what the player keeps in the pouch,
-- grouped; Take opens a small window to choose how many come out as stackable items (to trade). Using a stone item
-- puts it back (server side).
local OPCODE = 124

pouchWindow = nil
local withdrawWindow = nil
local pouchButton = nil
local pending = nil -- { key, name, amount } being withdrawn

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

local function showResult(status, message)
    if message and message ~= '' and modules.game_textmessage then
        if status == 'ok' then
            modules.game_textmessage.displayStatusMessage(message)
        else
            modules.game_textmessage.displayFailureMessage(message)
        end
    end
end

local function openWithdraw(currency)
    pending = currency
    withdrawWindow.what:setText(tr('How many %s? You have %d.', currency.name, currency.amount))
    withdrawWindow.count:setMinimum(1)
    withdrawWindow.count:setMaximum(currency.amount)
    withdrawWindow.count:setValue(1)
    withdrawWindow:show()
    withdrawWindow:raise()
    withdrawWindow:focus()
    withdrawWindow.count:focus()
end

-- every section shows with its title (General, League...), even empty
local function render(groups)
    local list = pouchWindow:getChildById('contentsPanel')
    list:destroyChildren()
    for _, group in ipairs(groups) do
        local title = g_ui.createWidget('PouchGroupTitle', list)
        title:setText(group.name)
        if #group.currencies == 0 then
            local empty = g_ui.createWidget('PouchEmpty', list)
            empty:setText(tr('Nothing here yet.'))
        end
        for _, currency in ipairs(group.currencies) do
            local row = g_ui.createWidget('PouchRow', list)
            row.name:setText(currency.name)
            row.amount:setText('x' .. currency.amount)
            row:setTooltip(currency.name .. '\n' .. (currency.description or ''))
            row.withdraw:setVisible(currency.withdrawable)
            row.withdraw.onClick = function()
                openWithdraw(currency)
            end
        end
    end
end

local function onMessage(protocol, opcode, data)
    if not pouchWindow or type(data) ~= 'table' then
        return
    end
    if data.action == 'view' then
        render(data.groups or {})
    elseif data.action == 'result' then
        showResult(data.status, data.message)
    end
end

function confirmWithdraw()
    if pending then
        send(string.format('withdraw:%s:%d', pending.key, withdrawWindow.count:getValue()))
    end
    cancelWithdraw()
end

function withdrawAll()
    if pending then
        withdrawWindow.count:setValue(pending.amount)
    end
end

function cancelWithdraw()
    pending = nil
    if withdrawWindow then
        withdrawWindow:hide()
    end
end

function onMiniWindowOpen()
    if pouchButton then
        pouchButton:setOn(true)
    end
    send('open')
end

function onMiniWindowClose()
    cancelWithdraw()
    if pouchButton then
        pouchButton:setOn(false)
    end
end

function toggle()
    if pouchButton:isOn() then
        pouchWindow:close()
    else
        if not pouchWindow:getParent() then
            local panel = modules.game_interface.findContentPanelAvailable(pouchWindow, pouchWindow:getMinimumHeight())
            if not panel then
                return
            end
            panel:addChild(pouchWindow)
        end
        pouchWindow:open()
    end
end

local function onGameStart()
    pouchWindow:setupOnStart() -- the window's place and size saved per character
    if pouchWindow:isVisible() then
        send('open')
    end
end

local function onGameEnd()
    cancelWithdraw()
    pouchWindow:getChildById('contentsPanel'):destroyChildren()
end

function init()
    pouchWindow = g_ui.loadUI('pouch')
    withdrawWindow = g_ui.displayUI('withdraw')
    withdrawWindow:hide()
    pouchWindow:setup()
    pouchWindow:setContentMinimumHeight(40)
    for _, id in ipairs({ 'toggleFilterButton', 'newWindowButton', 'contextMenuButton' }) do
        local button = pouchWindow:recursiveGetChildById(id)
        if button then
            button:setVisible(false)
        end
    end

    ProtocolGame.registerExtendedJSONOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    pouchButton = modules.game_mainpanel.addToggleButton('pouchButton', tr('Currency Pouch'),
        '/images/options/button_pouch', toggle, false, 9)
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedJSONOpcode(OPCODE)
    if pouchButton then
        pouchButton:destroy()
        pouchButton = nil
    end
    if withdrawWindow then
        withdrawWindow:destroy()
        withdrawWindow = nil
    end
    if pouchWindow then
        pouchWindow:destroy()
        pouchWindow = nil
    end
end
