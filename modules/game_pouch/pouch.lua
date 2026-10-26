-- Currency pouch window (server opcode 124, forgottenserver data/scripts/lib/currency_pouch.lua).
-- Lists what the player keeps in the pouch, grouped; Withdraw opens a small window to choose how many come out as
-- stackable items (to trade). Using a stone item in the bags puts it back (server side).
local OPCODE = 124
local RESULT_COLORS = { ok = '#7fd77f', error = '#e06060' }

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

local function setResult(status, message)
    pouchWindow.resultLabel:setText(message or '')
    pouchWindow.resultLabel:setColor(RESULT_COLORS[status] or '#c0c0c0')
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
    local list = pouchWindow.list
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
            if currency.clientId > 0 then
                row.icon:setItemId(currency.clientId)
            end
            row.name:setText(currency.name)
            row.amount:setText(tr('Amount: %d', currency.amount))
            row:setTooltip(currency.description)
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
        setResult(data.status, data.message)
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

function show()
    setResult(nil, '')
    pouchWindow:show()
    pouchWindow:raise()
    pouchWindow:focus()
    send('open')
end

function hide()
    cancelWithdraw()
    if pouchWindow then
        pouchWindow:hide()
    end
end

function toggle()
    if pouchWindow:isVisible() then
        hide()
    else
        show()
    end
end

local function reset()
    hide()
    if pouchWindow then
        pouchWindow.list:destroyChildren()
    end
end

function init()
    pouchWindow = g_ui.displayUI('pouch')
    withdrawWindow = g_ui.displayUI('withdraw')
    pouchWindow:hide()
    withdrawWindow:hide()
    ProtocolGame.registerExtendedJSONOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = reset })
    pouchButton = modules.game_mainpanel.addToggleButton('pouchButton', tr('Currency Pouch'),
        '/images/options/button_empty', toggle, false, 9)
end

function terminate()
    disconnect(g_game, { onGameEnd = reset })
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
