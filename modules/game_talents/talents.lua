-- Talent and paragon trees (server opcode 123, forgottenserver data/scripts/creaturescripts/player/talents_tree.lua).
-- The server sends the layout once per session ("layout": nodes with grid cell, links, kind) and a small "state"
-- after every change (ranks, free points, which nodes can be learned now). The window draws the nodes on a canvas
-- that can be dragged and zoomed, the links as thin rotated widgets, and buys a node on click (the server checks
-- everything again).
local OPCODE = 123
local MIN_CELL, MAX_CELL, DEFAULT_CELL = 6, 30, 12
-- paragon nodes come in columns/rows, not grid cells
local PARAGON_SCALE = 7
local RESULT_COLORS = { ok = '#7fd77f', error = '#e06060' }
local BORDER = { learned = '#d8b03c', available = '#3c8d3c', locked = '#4a4a4a' }
local LINK = { learned = '#d8b03c', other = '#4a4a4a' }
-- size (at the default cell) and background of each kind of node
local KINDS = {
    inicio = { 30, '#4a4a1f', 'Start' }, portal = { 26, '#1f3a4a', 'Portal' }, pequeno = { 16, '#2a2a2a', 'Talent' },
    notavel = { 22, '#3a2f1a', 'Notable' }, ['pedra-angular'] = { 28, '#4a1f1f', 'Keystone' },
    marco = { 22, '#2f1f4a', 'Level talent' }, ['notavel-de-classe'] = { 22, '#1f4a2f', 'Class notable' },
    ['pedra-angular-de-classe'] = { 28, '#4a1f1f', 'Class keystone' }, maestria = { 22, '#1f4a2f', 'Mastery' },
    despertar = { 26, '#1f4a2f', 'Awakening' }, paragon = { 36, '#2a2a3a', 'Paragon' }
}

talentsWindow = nil
local talentsButton = nil
local state = {
    tree = 'talent',
    layouts = {}, -- [tree] = layout message
    states = {}, -- [tree] = state message
    cell = { talent = DEFAULT_CELL, paragon = DEFAULT_CELL },
    offset = {}, -- [tree] = { x, y } of the grid origin inside the canvas
    nodeWidgets = {}, -- [node id] = widget
    linkWidgets = {}, -- { widget, from, to }
    drawn = nil, -- tree whose widgets are on the canvas
    drag = nil
}

local function send(text)
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, text)
    end
end

local function setResult(status, message)
    talentsWindow.resultLabel:setText(message or '')
    talentsWindow.resultLabel:setColor(RESULT_COLORS[status] or '#c0c0c0')
end

local function kindOf(node)
    return KINDS[node.kind] or KINDS.pequeno
end

local function nodeState(tree, node)
    local current = state.states[tree]
    if not current then
        return 'locked', 0
    end
    local rank = current.ranks[node.id] or 0
    if current.availableSet[node.id] then
        return 'available', rank
    end
    return rank > 0 and 'learned' or 'locked', rank
end

local function scaleOf(tree)
    return tree == 'paragon' and PARAGON_SCALE or 1
end

-- center of a node inside the canvas
local function nodeCenter(tree, node)
    local cell, offset = state.cell[tree], state.offset[tree]
    local scale = scaleOf(tree)
    return offset.x + node.x * scale * cell, offset.y + node.y * scale * cell
end

local function place(widget, x, y, width, height)
    widget:addAnchor(AnchorTop, 'parent', AnchorTop)
    widget:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    widget:setMarginTop(math.floor(y))
    widget:setMarginLeft(math.floor(x))
    widget:setSize({ width = math.max(1, math.floor(width)), height = math.max(1, math.floor(height)) })
end

local function reposition()
    local tree = state.drawn
    if not tree then
        return
    end
    local zoom = state.cell[tree] / DEFAULT_CELL
    local byId = state.layouts[tree].byId
    for _, entry in ipairs(state.linkWidgets) do
        local ax, ay = nodeCenter(tree, byId[entry.from])
        local bx, by = nodeCenter(tree, byId[entry.to])
        local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        place(entry.widget, (ax + bx) / 2 - length / 2, (ay + by) / 2 - 1, length, 2)
        entry.widget:setRotation(math.deg(math.atan2(by - ay, bx - ax)))
    end
    for id, widget in pairs(state.nodeWidgets) do
        local node = byId[id]
        local size = kindOf(node)[1] * math.max(0.6, zoom)
        local x, y = nodeCenter(tree, node)
        place(widget, x - size / 2, y - size / 2, size, size)
    end
end

local function tooltip(tree, node)
    local status, rank = nodeState(tree, node)
    local lines = { node.name, tr(kindOf(node)[3]) }
    table.insert(lines, node.maxRank > 0 and tr('Rank: %d/%d', rank, node.maxRank) or tr('Rank: %d (no limit)', rank))
    table.insert(lines, tr('Each rank: %s', node.text))
    if node.level and node.level > 0 then
        table.insert(lines, tr('Opens at level %d.', node.level))
    end
    if node.class and node.class ~= '' then
        table.insert(lines, tr('Class branch: %s', node.class))
    end
    if status == 'available' then
        table.insert(lines, tr('Click to learn.'))
    elseif rank == 0 then
        table.insert(lines, tr('Not available yet.'))
    end
    return table.concat(lines, '\n')
end

local function paintState(tree)
    if state.drawn ~= tree then
        return
    end
    local current = state.states[tree]
    local byId = state.layouts[tree].byId
    for id, widget in pairs(state.nodeWidgets) do
        local node = byId[id]
        local status, rank = nodeState(tree, node)
        widget:setBorderColor(BORDER[status])
        widget:setText(rank > 0 and tostring(rank) or '')
        widget:setTooltip(tooltip(tree, node))
        widget:setOpacity(status == 'locked' and rank == 0 and 0.55 or 1)
    end
    for _, entry in ipairs(state.linkWidgets) do
        local learned = (current.ranks[entry.from] or 0) > 0 and (current.ranks[entry.to] or 0) > 0
        entry.widget:setBackgroundColor(learned and LINK.learned or LINK.other)
    end
    talentsWindow.points:setText(tr('Free points: %d', current.free))
    if tree == 'talent' then
        talentsWindow.keystones:setText(tr('Keystones: %d/%d', current.keystones, current.maxKeystones))
        talentsWindow.resetButton:setVisible(true)
        talentsWindow.resetButton:setText(current.resetCost > 0 and tr('Reset (%d gp)', current.resetCost) or tr('Reset (free)'))
        talentsWindow.resetButton:setEnabled(current.atTemple)
        talentsWindow.resetButton:setTooltip(current.atTemple and '' or tr('Talents are reset at the temple.'))
    else
        talentsWindow.keystones:setText('')
        talentsWindow.resetButton:setVisible(false)
    end
end

function center()
    local tree = state.tree
    local canvas = talentsWindow.canvas
    state.offset[tree] = { x = canvas:getWidth() / 2, y = canvas:getHeight() / 2 }
    if tree == 'paragon' then
        state.offset[tree] = { x = 60, y = 60 }
    end
    reposition()
end

local function draw(tree)
    local layout = state.layouts[tree]
    local canvas = talentsWindow.canvas
    -- keep the hint label, drop everything else
    for _, child in ipairs(canvas:getChildren()) do
        child:destroy()
    end
    state.nodeWidgets, state.linkWidgets, state.drawn = {}, {}, tree
    talentsWindow:setText(layout.name)
    talentsWindow.talentTab:setOn(tree == 'talent')
    talentsWindow.paragonTab:setOn(tree == 'paragon')

    -- links first, so the nodes are drawn over them; each pair once
    local seen = {}
    for _, node in ipairs(layout.nodes) do
        for _, other in ipairs(node.links) do
            local key = node.id < other and (node.id .. '|' .. other) or (other .. '|' .. node.id)
            if layout.byId[other] and not seen[key] then
                seen[key] = true
                table.insert(state.linkWidgets,
                    { widget = g_ui.createWidget('TalentLink', canvas), from = node.id, to = other })
            end
        end
    end
    for _, node in ipairs(layout.nodes) do
        local widget = g_ui.createWidget('TalentNode', canvas)
        widget:setBackgroundColor(kindOf(node)[2])
        local nodeId = node.id
        widget.onClick = function()
            send(string.format('buy:%s:%s', state.tree, nodeId))
        end
        state.nodeWidgets[node.id] = widget
    end
    if not state.offset[tree] then
        center()
    else
        reposition()
    end
    if state.states[tree] then
        paintState(tree)
    end
end

local function onMessage(protocol, opcode, data)
    if not talentsWindow or type(data) ~= 'table' then
        return
    end
    if data.action == 'layout' then
        data.byId = {}
        for _, node in ipairs(data.nodes) do
            data.byId[node.id] = node
        end
        state.layouts[data.tree] = data
        if data.tree == state.tree then
            draw(data.tree)
        end
    elseif data.action == 'state' then
        data.availableSet = {}
        for _, id in ipairs(data.available) do
            data.availableSet[id] = true
        end
        state.states[data.tree] = data
        if data.tree == state.tree and state.drawn ~= data.tree and state.layouts[data.tree] then
            draw(data.tree)
        end
        paintState(data.tree)
    elseif data.action == 'result' then
        setResult(data.status, data.message)
    end
end

function open(tree)
    state.tree = tree
    setResult(nil, '')
    if state.layouts[tree] and state.drawn ~= tree then
        draw(tree)
    end
    send('open:' .. tree)
end

function askReset()
    local current = state.states.talent
    if not current then
        return
    end
    local message = current.resetCost > 0 and tr('Reset every talent for %d gold? Your points come back.', current.resetCost) or
        tr('Your next reset is free. Reset every talent now?')
    local box
    local function close()
        if box then
            box:destroy()
            box = nil
        end
    end
    box = displayGeneralBox(tr('Reset talents'), message, {
        { text = tr('Reset'), callback = function()
            close()
            send('reset:talent')
        end },
        { text = tr('Cancel'), callback = close },
        anchor = AnchorHorizontalCenter
    }, close, close)
end

-- drag the canvas to move the tree, mouse wheel to zoom around the pointer
local function setupCanvas()
    local canvas = talentsWindow.canvas
    canvas:setDraggable(true)
    canvas.onDragEnter = function(self, mousePos)
        state.drag = { x = mousePos.x, y = mousePos.y }
        return true
    end
    canvas.onDragMove = function(self, mousePos)
        local tree = state.drawn
        if not state.drag or not tree then
            return false
        end
        local offset = state.offset[tree]
        offset.x = offset.x + mousePos.x - state.drag.x
        offset.y = offset.y + mousePos.y - state.drag.y
        state.drag = { x = mousePos.x, y = mousePos.y }
        reposition()
        return true
    end
    canvas.onDragLeave = function()
        state.drag = nil
        return true
    end
    canvas.onMouseWheel = function(self, mousePos, direction)
        local tree = state.drawn
        if not tree then
            return false
        end
        local old = state.cell[tree]
        local new = math.max(MIN_CELL, math.min(MAX_CELL, old + (direction == MouseWheelUp and 2 or -2)))
        if new == old then
            return true
        end
        -- keep the point under the mouse where it is
        local rect = self:getRect()
        local px, py = mousePos.x - rect.x, mousePos.y - rect.y
        local offset = state.offset[tree]
        offset.x = px - (px - offset.x) * new / old
        offset.y = py - (py - offset.y) * new / old
        state.cell[tree] = new
        reposition()
        return true
    end
end

function show()
    talentsWindow:show()
    talentsWindow:raise()
    talentsWindow:focus()
    open(state.tree)
end

function hide()
    if talentsWindow then
        talentsWindow:hide()
    end
end

function toggle()
    if talentsWindow:isVisible() then
        hide()
    else
        show()
    end
end

local function reset()
    hide()
    state.layouts, state.states, state.offset, state.drawn = {}, {}, {}, nil
    state.nodeWidgets, state.linkWidgets = {}, {}
    if talentsWindow then
        for _, child in ipairs(talentsWindow.canvas:getChildren()) do
            child:destroy()
        end
    end
end

function init()
    talentsWindow = g_ui.displayUI('talents')
    talentsWindow:hide()
    setupCanvas()
    ProtocolGame.registerExtendedJSONOpcode(OPCODE, onMessage)
    connect(g_game, { onGameEnd = reset })
    talentsButton = modules.game_mainpanel.addToggleButton('talentsButton', tr('Talents'),
        '/images/options/button_skillwheeldialog', toggle, false, 10)
end

function terminate()
    disconnect(g_game, { onGameEnd = reset })
    ProtocolGame.unregisterExtendedJSONOpcode(OPCODE)
    if talentsButton then
        talentsButton:destroy()
        talentsButton = nil
    end
    if talentsWindow then
        talentsWindow:destroy()
        talentsWindow = nil
    end
end
