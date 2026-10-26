-- Buff and debuff bars (server opcode 122, data/scripts/lib/buffs.lua on the server).
-- The server says when a condition starts, is renewed or ends, with its time left; the bars count down by
-- themselves and trust the next message. Each bar floats over the game (FloatingPanel): the player drags it, locks it
-- with a right click and chooses there which categories it shows.
local OPCODE = 122
local CATEGORIES = { 'spell', 'food', 'talent', 'item', 'other' }
local CATEGORY_NAMES = {
    spell = tr('Spells'), food = tr('Food'), talent = tr('Talents'), item = tr('Items'), other = tr('Others')
}
local FILTERS_NODE = 'BuffBarFilters'
local SPELL_ICONS = '/images/game/spells/spell-icons-32x32'
local STATE_ICONS = '/images/game/states/player-state-flags'
local FOOD_ITEM = 3582 -- ham

-- condition type (ConditionType_t on the server) -> what the square shows: a spell icon, an item, or the small
-- state flag of the status bar; name and text for the tooltip (the state's own tooltip is used when there is one)
local CONDITIONS = {
    [1] = { name = tr('Poisoned'), state = PlayerStates.Poison },
    [2] = { name = tr('Burning'), state = PlayerStates.Burn },
    [4] = { name = tr('Electrified'), state = PlayerStates.Energy },
    [8] = { name = tr('Bleeding'), state = PlayerStates.Bleeding },
    [16] = { name = tr('Haste'), spell = 'Haste', state = PlayerStates.Haste },
    [32] = { name = tr('Paralyzed'), state = PlayerStates.Paralyze },
    [64] = { name = tr('Disguised'), text = tr('Your outfit was changed.') },
    [128] = { name = tr('Invisible'), spell = 'Invisibility', text = tr('Creatures cannot see you.') },
    [256] = { name = tr('Light'), spell = 'Light', text = tr('You give off light.') },
    [512] = { name = tr('Magic Shield'), spell = 'Magic Shield', state = PlayerStates.ManaShield },
    [2048] = { name = tr('Drunk'), state = PlayerStates.Drunk },
    [8192] = { name = tr('Well fed'), item = FOOD_ITEM,
        text = tr('You regenerate health and mana until you get hungry.') },
    [32768] = { name = tr('Drowning'), state = PlayerStates.Drowning },
    [524288] = { name = tr('Strengthened'), spell = 'Blood Rage', state = PlayerStates.PartyBuff },
    [1048576] = { name = tr('Freezing'), state = PlayerStates.Freezing },
    [2097152] = { name = tr('Dazzled'), state = PlayerStates.Dazzled },
    [4194304] = { name = tr('Cursed'), state = PlayerStates.Cursed },
    [33554432] = { name = tr('Pacified'), text = tr('You cannot attack.') },
    [268435456] = { name = tr('Rooted'), state = PlayerStates.Rooted },
    [536870912] = { name = tr('Magic Shield'), spell = 'Magic Shield', state = PlayerStates.NewManaShield }
}

local bars = {}       -- kind ('buff'/'debuff') -> bar widget
local entries = {}    -- key -> { kind, category, endsAt (ms, nil = no end), widget }
local tickEvent = nil

local function stateInfo(state)
    for _, info in pairs(ConditionIcons) do
        if info.state == state then
            return info
        end
    end
end

local function loadFilters(kind)
    local all = g_settings.getNode(FILTERS_NODE) or {}
    return all[kind] or {}
end

local function shows(kind, category)
    return loadFilters(kind)[category] ~= false
end

local function setShows(kind, category, visible)
    local all = g_settings.getNode(FILTERS_NODE) or {}
    all[kind] = all[kind] or {}
    all[kind][category] = visible
    g_settings.setNode(FILTERS_NODE, all)
end

local function formatTime(ms)
    if not ms then
        return ''
    end
    local seconds = math.max(0, math.ceil(ms / 1000))
    if seconds >= 3600 then
        return string.format('%dh', math.floor(seconds / 3600))
    elseif seconds >= 60 then
        return string.format('%d:%02d', math.floor(seconds / 60), seconds % 60)
    end
    return string.format('%ds', seconds)
end

local function decorate(square, conditionType, kind)
    local info = CONDITIONS[conditionType] or { name = tr('Effect') }
    local state = info.state and stateInfo(info.state)
    local spell = info.spell and SpellInfo.Default[info.spell]

    square.frame:setBorderColor(kind == 'debuff' and '#b53434' or '#3c8d3c')
    if spell then
        square.icon:setImageSource(SPELL_ICONS)
        square.icon:setImageClip(Spells.getImageClip(spell.clientId, 'Default'))
    elseif info.item then
        square.icon:hide()
        square.item:setItemId(info.item)
        square.item:show()
    elseif state then
        square.icon:setImageSource(STATE_ICONS)
        square.icon:setImageClip(((state.clip - 1) * 9) .. ' 0 9 9')
        square.icon:setSize({ width = 18, height = 18 })
    else
        square.icon:hide()
        square.initials:setText(info.name:sub(1, 2))
        square.initials:show()
    end

    local text = info.text or (state and state.tooltip) or ''
    square:setTooltip(info.name .. (text ~= '' and ('\n' .. text) or ''))
end

local function refreshBar(kind)
    local bar = bars[kind]
    if bar then
        bar:setVisible(bar:getChildCount() > 0)
        -- a bar that grew must stay on screen (after the layout has the new width)
        addEvent(bar.floatingFit)
    end
end

local function removeEntry(key)
    local entry = entries[key]
    if not entry then
        return
    end
    entries[key] = nil
    if entry.widget then
        entry.widget:destroy()
    end
    refreshBar(entry.kind)
end

local function placeEntry(key)
    local entry = entries[key]
    local wanted = shows(entry.kind, entry.category)
    if wanted and not entry.widget then
        entry.widget = g_ui.createWidget('BuffSquare', bars[entry.kind])
        decorate(entry.widget, entry.conditionType, entry.kind)
    elseif not wanted and entry.widget then
        entry.widget:destroy()
        entry.widget = nil
    end
    if entry.widget then
        entry.widget.time:setText(entry.endsAt and formatTime(entry.endsAt - g_clock.millis()) or '')
    end
    refreshBar(entry.kind)
end

local function tick()
    local now = g_clock.millis()
    for key, entry in pairs(entries) do
        if entry.endsAt and entry.endsAt <= now then
            -- the server's "del" follows; the square goes now so it never shows 0s for long
            removeEntry(key)
        elseif entry.widget and entry.endsAt then
            entry.widget.time:setText(formatTime(entry.endsAt - now))
        end
    end
end

local function onMessage(protocol, opcode, buffer)
    local parts = buffer:split(':')
    local action = parts[1]
    if action == 'set' and #parts == 8 then
        local key = parts[2] .. ':' .. parts[3] .. ':' .. parts[4]
        local remaining = tonumber(parts[5]) or -1
        local entry = entries[key] or {}
        entries[key] = entry
        entry.conditionType = tonumber(parts[2])
        entry.kind = parts[6] == 'debuff' and 'debuff' or 'buff'
        entry.category = parts[7]
        entry.endsAt = remaining >= 0 and g_clock.millis() + remaining or nil
        placeEntry(key)
    elseif action == 'del' and #parts == 4 then
        removeEntry(parts[2] .. ':' .. parts[3] .. ':' .. parts[4])
    end
end

local function clearAll()
    for key in pairs(entries) do
        removeEntry(key)
    end
end

local function filterMenu(kind)
    return function(menu)
        menu:addSeparator()
        for _, category in ipairs(CATEGORIES) do
            menu:addCheckBox(CATEGORY_NAMES[category], shows(kind, category), function(_, checked)
                setShows(kind, category, checked)
                for key, entry in pairs(entries) do
                    if entry.kind == kind then
                        placeEntry(key)
                    end
                end
            end)
        end
    end
end

local function createBar(kind, defaultPos)
    local bar = g_ui.createWidget('BuffBar', modules.game_interface.getRootPanel())
    bar:setId(kind .. 'Bar')
    bar:hide()
    FloatingPanel.attach(bar, kind .. 'Bar', filterMenu(kind))
    bar.floatingDefault = defaultPos
    return bar
end

local function onGameStart()
    clearAll()
    -- buffs top left, debuffs top right of the game screen
    local root = modules.game_interface.getRootPanel()
    FloatingPanel.restore(bars.buff, bars.buff.floatingDefault)
    FloatingPanel.restore(bars.debuff, { x = root:getWidth() - 260, y = 40 })
    tickEvent = cycleEvent(tick, 1000)
end

local function onGameEnd()
    if tickEvent then
        removeEvent(tickEvent)
        tickEvent = nil
    end
    clearAll()
end

function init()
    g_ui.importStyle('buffs')
    bars.buff = createBar('buff', { x = 180, y = 40 })
    bars.debuff = createBar('debuff', { x = 600, y = 40 })
    ProtocolGame.registerExtendedOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    ProtocolGame.unregisterExtendedOpcode(OPCODE)
    onGameEnd()
    for _, bar in pairs(bars) do
        FloatingPanel.detach(bar)
        bar:destroy()
    end
    bars = {}
end
