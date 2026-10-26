-- Reforge window: drop an item on the slot, pick a stone, apply. Talks to the server on extended opcode 121
-- (forgottenserver data/scripts/creaturescripts/player/reforge.lua). The item really moves into the window (the
-- server keeps it on a bench saved with the character) and goes back to the bags when the window closes.

local OPCODE = 121

local RESULT_COLORS = { ok = '#7fd77f', failed = '#e0a050', error = '#e06060' }
local RARITY_COLORS = { Common = '#b0b0b0', Uncommon = '#5ac85a', Rare = '#4a9cf0', Legendary = '#f08c28' }
local LINE_COLORS = { prefix = '#8fc4ff', suffix = '#c8a8ff', locked = '#e8c860' }
local CHANGED_BACKGROUND = '#3c8d3c55' -- lines that a stone just added or changed

reforgeWindow = nil
local reforgeButton = nil

local state = {
    item = nil,          -- item data from the server
    stones = {},         -- stones the player carries
    stoneKey = nil,      -- "<type>:<category>" of the selected stone
    lineIndex = nil,     -- selected line (for stones that remove a chosen line)
    previousLines = nil  -- line texts before the last stone, to show what it changed
}

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

local function stoneKey(stone)
    return stone.type .. ':' .. (stone.category or '')
end

local function selectedStone()
    for _, stone in ipairs(state.stones) do
        if stoneKey(stone) == state.stoneKey then
            return stone
        end
    end
    return nil
end

local function setResult(status, message)
    reforgeWindow.resultLabel:setText(message or '')
    reforgeWindow.resultLabel:setColor(RESULT_COLORS[status] or '#c0c0c0')
end

local function updateStoneInfo()
    local stone = selectedStone()
    local info = reforgeWindow.stoneInfo
    reforgeWindow.affixChoice:setVisible(stone ~= nil and stone.needs == 'affix')
    if not stone then
        info:setText(tr('Choose a stone.'))
        return
    end

    local chance = state.item and state.item.chances[stone.type] or stone.chance
    local text = stone.description
    if stone.category ~= '' then
        text = text .. ' (' .. stone.category .. ')'
    end
    text = text .. '\n' .. tr('Success chance') .. ': ' .. chance .. '%'
    if stone.needs == 'line' then
        text = text .. '\n' .. tr('Select the line to remove.')
    end
    info:setText(text)
end

local function renderLines()
    local list = reforgeWindow.linesList
    list:destroyChildren()
    local item = state.item
    if not item then
        reforgeWindow.vacancies:setText('')
        return
    end

    local before = {}
    for _, text in ipairs(state.previousLines or {}) do
        before[text] = true
    end

    local lastAffix = nil
    for _, line in ipairs(item.lines) do
        -- the server sends prefixes first, then suffixes
        if line.affix ~= lastAffix then
            lastAffix = line.affix
            local header = g_ui.createWidget('ReforgeRow', list)
            header:setText(line.affix == 'prefix' and tr('Prefixes') or tr('Suffixes'))
            header:setFocusable(false)
            header:setColor('#8a8a8a')
        end
        local row = g_ui.createWidget('ReforgeRow', list)
        row:setText('  ' .. line.text .. (line.locked and '  [locked]' or ''))
        row:setColor(line.locked and LINE_COLORS.locked or LINE_COLORS[line.affix])
        if state.previousLines and not before[line.text] then
            row:setBackgroundColor(CHANGED_BACKGROUND)
            row:setTooltip(tr('Changed by the last stone'))
        end
        local index = line.index
        row.onFocusChange = function(_, focused)
            if focused then
                state.lineIndex = index
            end
        end
        if index == state.lineIndex then
            list:focusChild(row, ActiveFocusReason)
        end
    end

    reforgeWindow.vacancies:setText(string.format('%s %d/%d   %s %d/%d', tr('Prefixes'), item.prefixes.used,
        item.prefixes.max, tr('Suffixes'), item.suffixes.used, item.suffixes.max))
end

local function renderStones()
    local list = reforgeWindow.stonesList
    list:destroyChildren()
    if #state.stones == 0 then
        local row = g_ui.createWidget('ReforgeRow', list)
        row:setText(tr('You have no stones.'))
        row:setFocusable(false)
    end

    for _, stone in ipairs(state.stones) do
        local row = g_ui.createWidget('ReforgeRow', list)
        local name = stone.name .. (stone.category ~= '' and (' [' .. stone.category .. ']') or '')
        local chance = state.item and state.item.chances[stone.type] or stone.chance
        row:setText(string.format('%s  x%d%s', name, stone.count, chance < 100 and ('  ' .. chance .. '%') or ''))
        local key = stoneKey(stone)
        row.onFocusChange = function(_, focused)
            if focused then
                state.stoneKey = key
                updateStoneInfo()
            end
        end
        if key == state.stoneKey then
            list:focusChild(row, ActiveFocusReason)
        end
    end
    updateStoneInfo()
end

local function renderItem()
    local item = state.item
    if not item then
        reforgeWindow.itemSlot:setItem(nil)
        reforgeWindow.itemName:setText(tr('Drag an item here'))
        reforgeWindow.itemRarity:setText('')
        return
    end
    reforgeWindow.itemSlot:setItem(Item.create(item.clientId))
    reforgeWindow.itemName:setText(item.name)
    reforgeWindow.itemRarity:setText(tr('Rarity') .. ': ' .. item.rarity)
    reforgeWindow.itemRarity:setColor(RARITY_COLORS[item.rarity] or '#c0c0c0')
end

local function onMessage(protocol, opcode, data)
    if not reforgeWindow or type(data) ~= 'table' then
        return
    end

    if data.stones then
        state.stones = data.stones
    end

    if data.action == 'open' then
        if data.selected and data.selected ~= '' then
            state.stoneKey = data.selected .. ':' .. (data.selectedCategory or '')
        end
        reforgeWindow:show()
        reforgeWindow:raise()
        reforgeWindow:focus()
    elseif data.action == 'item' then
        state.item = data.item
        -- the selected line may be gone after a stone
        if state.lineIndex and state.lineIndex > #data.item.lines then
            state.lineIndex = nil
        end
        renderItem()
        renderLines()
    elseif data.action == 'empty' then
        state.item = nil
        state.lineIndex = nil
        state.previousLines = nil
        renderItem()
        renderLines()
    elseif data.action == 'result' then
        setResult(data.status, data.message)
        return
    end
    renderStones()
end

-- the slot accepts items from the inventory or from containers (the server checks the rest)
local function onSlotDrop(self, widget, mousePos)
    local item = widget and widget.currentDragThing
    if not item or not item:isItem() then
        return false
    end
    local position = item:getPosition()
    if position.x ~= 65535 then
        setResult('error', tr('Pick the item up first: only items you carry can be reforged.'))
        return true
    end
    state.lineIndex = nil
    state.previousLines = nil
    setResult(nil, '')
    send(string.format('select:%d:%d:%d', position.x, position.y, position.z))
    return true
end

function apply()
    local stone = selectedStone()
    if not state.item then
        setResult('error', tr('Drag an item to the slot first.'))
        return
    end
    if not stone then
        setResult('error', tr('Choose a stone.'))
        return
    end

    local extra = '-'
    if stone.needs == 'affix' then
        extra = reforgeWindow.affixChoice:getCurrentOption().data
    elseif stone.needs == 'line' then
        if not state.lineIndex then
            setResult('error', tr('Select the line to remove.'))
            return
        end
        extra = tostring(state.lineIndex)
    end

    -- remember the lines so the answer can show what the stone changed
    state.previousLines = {}
    for _, line in ipairs(state.item.lines) do
        table.insert(state.previousLines, line.text)
    end
    send(string.format('apply:%s:%s:%s', stone.type, stone.category ~= '' and stone.category or '-', extra))
end

function show()
    send('open')
end

function hide()
    if reforgeWindow then
        reforgeWindow:hide()
    end
    -- closing the window gives the item back
    if state.item then
        send('take')
        state.item = nil
        state.previousLines = nil
        renderItem()
    end
end

-- while the window is open, any change in bags or equipment may add or remove stones: ask the server again,
-- once per burst of changes
local refreshEvent = nil
local function scheduleRefresh()
    if not reforgeWindow or not reforgeWindow:isVisible() or refreshEvent then
        return
    end
    refreshEvent = scheduleEvent(function()
        refreshEvent = nil
        if reforgeWindow and reforgeWindow:isVisible() then
            send('refresh')
        end
    end, 250)
end

local CONTAINER_EVENTS = { onAddItem = scheduleRefresh, onRemoveItem = scheduleRefresh, onUpdateItem = scheduleRefresh }
local PLAYER_EVENTS = { onInventoryChange = scheduleRefresh }

local function reset()
    state.item = nil
    state.stones = {}
    state.stoneKey = nil
    state.lineIndex = nil
    state.previousLines = nil
    if reforgeWindow then
        reforgeWindow:hide()
        renderItem()
        reforgeWindow.linesList:destroyChildren()
        reforgeWindow.stonesList:destroyChildren()
        setResult(nil, '')
    end
end

function init()
    reforgeWindow = g_ui.displayUI('reforge')
    reforgeWindow:hide()
    reforgeWindow.itemSlot.onDrop = onSlotDrop
    reforgeWindow.affixChoice:addOption(tr('Prefix'), 'prefix')
    reforgeWindow.affixChoice:addOption(tr('Suffix'), 'suffix')

    ProtocolGame.registerExtendedJSONOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = reset })
    connect(Container, CONTAINER_EVENTS)
    connect(LocalPlayer, PLAYER_EVENTS)

    -- opens the window without a stone in hand; the server lists the stones in every bag the player carries
    reforgeButton = modules.game_mainpanel.addToggleButton('reforgeButton', tr('Reforge'),
        '/images/options/button-exaltation-forge', toggle, false, 8)
end

function toggle()
    if reforgeWindow and reforgeWindow:isVisible() then
        hide()
    else
        show()
    end
end

function terminate()
    disconnect(g_game, { onGameEnd = reset })
    disconnect(Container, CONTAINER_EVENTS)
    disconnect(LocalPlayer, PLAYER_EVENTS)
    if refreshEvent then
        removeEvent(refreshEvent)
        refreshEvent = nil
    end
    if reforgeButton then
        reforgeButton:destroy()
        reforgeButton = nil
    end
    ProtocolGame.unregisterExtendedJSONOpcode(OPCODE)
    if reforgeWindow then
        reforgeWindow:destroy()
        reforgeWindow = nil
    end
end
