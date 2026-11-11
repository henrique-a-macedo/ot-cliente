-- Talent and paragon trees (server opcode 123, forgottenserver data/scripts/creaturescripts/player/talents_tree.lua).
-- The server sends the layout once per session ("layout": nodes with grid cell, links, kind, level) and a small
-- "state" after every change (ranks, free points, class points, which nodes can be learned now). The window shows
-- the nodes on a canvas that can be dragged and zoomed and buys a node on click (the server checks everything again).
-- The tree has ~720 nodes, so nothing is anchored: every widget gets an absolute rect from reposition(), and only
-- the widgets that touch the canvas are moved (the others are hidden). A node is one widget: sprite = fill, icon = ring.
local OPCODE = 123
local MIN_CELL, MAX_CELL = 0.8, 30
local ZOOM_STEP = 1.2
-- paragon nodes come in columns/rows, not grid cells
local PARAGON_SCALE = 7
local LEGACY_CELL = 12 -- the old trees were sized in pixels at 12 px per cell
local RESULT_COLORS = { ok = '#7fd77f', error = '#e06060' }
local IMG = '/images/game/talents/'
local BG = '#16141b'
local GOLD = '#d8b25a'
local NEUTRAL = '#8d8899'
local CLASS_COLOR = '#4fae6e'
local LINK = { owned = '#8d8899', other = '#4a4556' }
-- region colors: the sector is picked by the angle of the node around the center (y grows downwards)
local SECTORS = { { -135, '#ef5a4c' }, { -45, '#39c2c4' }, { 45, '#9c86ff' }, { 135, '#5cc77a' } }
local DIVISIONS = { 0, 90, 180, -90 } -- travel nodes this close (degrees) to a division are neutral
local DIVISION_WIDTH = 9
-- level bands: hexagon outlines (radius in cells), vertices at -150..150 degrees, dashed
local BANDS = { { level = 50, radius = 93.18, color = '#4aa0ff' }, { level = 120, radius = 147.73, color = '#ff9a40' } }
local BAND_COLORS = { [50] = '#4aa0ff', [120] = '#ff9a40' }
local HEX_ANGLES = { -150, -90, -30, 30, 90, 150 }
local DASH_PERIOD, DASH_LENGTH = 7, 4 -- cells
-- node diameter in cells (notable = 4.2): travel 0.46, small 0.54, notable 1.0, keystone 1.35, start 1.45
local NOTABLE = 4.2
-- { diameter (cells), shape, hollow, color (nil = region color), fill strength when not owned, tooltip label }
local KINDS = {
    inicio = { NOTABLE * 1.45, 'disc', false, GOLD, 0.2, 'Start' },
    travessia = { NOTABLE * 0.46, 'disc', true, nil, 0, 'Travel' },
    pequeno = { NOTABLE * 0.54, 'disc', false, nil, 0.33, 'Talent' },
    notavel = { NOTABLE, 'disc', false, nil, 0.25, 'Notable' },
    ['pedra-angular'] = { NOTABLE * 1.35, 'square', false, GOLD, 0.2, 'Keystone' },
    -- class tree and older trees keep their old pixel sizes
    portal = { 26 / LEGACY_CELL, 'disc', false, '#39c2c4', 0.3, 'Portal' },
    marco = { 22 / LEGACY_CELL, 'disc', false, '#9c86ff', 0.3, 'Level talent' },
    ['notavel-de-classe'] = { 22 / LEGACY_CELL, 'disc', false, CLASS_COLOR, 0.25, 'Class notable' },
    ['pedra-angular-de-classe'] = { 28 / LEGACY_CELL, 'square', false, GOLD, 0.2, 'Class keystone' },
    maestria = { 22 / LEGACY_CELL, 'disc', false, CLASS_COLOR, 0.25, 'Mastery' },
    despertar = { 26 / LEGACY_CELL, 'disc', false, CLASS_COLOR, 0.3, 'Awakening' },
    paragon = { 36 / LEGACY_CELL, 'square', false, NEUTRAL, 0.3, 'Paragon' }
}

talentsWindow = nil
local talentsButton = nil
local state = {
    tree = 'talent',
    layouts = {}, -- [tree] = layout message
    states = {}, -- [tree] = state message
    cell = {}, -- [tree] = pixels per cell
    offset = {}, -- [tree] = { x, y } of the grid origin inside the canvas
    entries = {}, -- [node id] = { node, widget, cx, cy, d, color, shown, size }
    segs = {}, -- links and band dashes: { widget, ax, ay, bx, by, len, th, minPx, from, to, shown }
    labels = {}, -- band labels: { widget, cx, cy, shown }
    drawn = nil, -- tree whose widgets are on the canvas
    pendingFit = false,
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

-- colors ---------------------------------------------------------------------------------------------------------

local function parseColor(hex)
    return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

-- amount of `a` in the mix (0 = all `b`)
local function mix(a, b, amount)
    local ar, ag, ab = parseColor(a)
    local br, bg, bb = parseColor(b)
    return string.format('#%02x%02x%02x', math.floor(ar * amount + br * (1 - amount) + 0.5),
        math.floor(ag * amount + bg * (1 - amount) + 0.5), math.floor(ab * amount + bb * (1 - amount) + 0.5))
end

local function angleDiff(a, b)
    return math.abs(((a - b + 540) % 360) - 180)
end

local function regionColor(x, y, isTravel)
    local angle = math.deg(math.atan2(y, x))
    if isTravel then
        for _, division in ipairs(DIVISIONS) do
            if angleDiff(angle, division) < DIVISION_WIDTH then
                return NEUTRAL
            end
        end
    end
    for _, sector in ipairs(SECTORS) do
        if angleDiff(angle, sector[1]) <= 45 then
            return sector[2]
        end
    end
    return SECTORS[1][2]
end

local function nodeColor(node)
    local kind = kindOf(node)
    if kind[4] then
        return kind[4]
    end
    if node.class and node.class ~= '' then
        return CLASS_COLOR
    end
    return regionColor(node.x, node.y, node.kind == 'travessia')
end

-- state ----------------------------------------------------------------------------------------------------------

local function isOwned(node, current)
    return node.free == true or (current ~= nil and (current.ranks[node.id] or 0) > 0)
end

-- 'owned' | 'available' | 'locked', rank
local function nodeState(tree, node)
    local current = state.states[tree]
    local rank = current and current.ranks[node.id] or 0
    if node.free == true then
        return 'owned', math.max(rank, 1)
    end
    if rank > 0 then
        return 'owned', rank
    end
    if current and current.availableSet[node.id] then
        return 'available', rank
    end
    return 'locked', rank
end

local function playerLevel()
    local player = g_game.getLocalPlayer()
    return player and player:getLevel() or 0
end

local function tooltip(node, status, rank, level)
    local lines = { node.name, tr(kindOf(node)[6]) }
    if (node.maxRank or 0) > 1 then
        table.insert(lines, tr('Rank: %d/%d', rank, node.maxRank))
    end
    table.insert(lines, node.text)
    if node.level and node.level > 0 and status ~= 'owned' then
        if level < node.level then
            table.insert(lines, tr('Requires level %d', node.level))
        else
            table.insert(lines, tr('Opens at level %d.', node.level))
        end
    end
    if node.class and node.class ~= '' then
        table.insert(lines, tr('Class branch: %s', node.class))
    end
    if status == 'available' then
        table.insert(lines, tr('Click to learn.'))
    elseif status == 'locked' then
        table.insert(lines, tr('Not available yet.'))
    end
    return table.concat(lines, '\n')
end

-- geometry -------------------------------------------------------------------------------------------------------

local function scaleOf(tree)
    return tree == 'paragon' and PARAGON_SCALE or 1
end

local function hideItem(item)
    if item.shown then
        item.shown = false
        item.widget:setVisible(false)
    end
end

local function showItem(item)
    if not item.shown then
        item.shown = true
        item.widget:setVisible(true)
    end
end

-- puts every widget that touches the canvas where it belongs and hides the rest
local function reposition()
    local tree = state.drawn
    if not tree or not talentsWindow then
        return
    end
    local rect = talentsWindow.canvas:getRect()
    local cell, offset = state.cell[tree], state.offset[tree]
    local ox, oy = rect.x + offset.x, rect.y + offset.y
    local left, top = rect.x - 24, rect.y - 24
    local right, bottom = rect.x + rect.width + 24, rect.y + rect.height + 24
    local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

    for _, seg in ipairs(state.segs) do
        local ax, ay, bx, by = ox + seg.ax * cell, oy + seg.ay * cell, ox + seg.bx * cell, oy + seg.by * cell
        if max(ax, bx) < left or min(ax, bx) > right or max(ay, by) < top or min(ay, by) > bottom then
            hideItem(seg)
        else
            local length = seg.len * cell
            local thickness = max(seg.minPx, floor(seg.th * cell + 0.5))
            seg.widget:setRect({ x = floor((ax + bx) / 2 - length / 2), y = floor((ay + by) / 2 - thickness / 2),
                width = max(1, ceil(length)), height = thickness })
            showItem(seg)
        end
    end
    for _, label in ipairs(state.labels) do
        local x, y = ox + label.cx * cell, oy + label.cy * cell
        if x < left - 60 or x > right + 60 or y < top or y > bottom then
            hideItem(label)
        else
            label.widget:setRect({ x = floor(x - 60), y = floor(y - 7), width = 120, height = 14 })
            showItem(label)
        end
    end
    for _, entry in pairs(state.entries) do
        local size = max(4, floor(entry.d * cell + 0.5))
        local x, y = ox + entry.cx * cell, oy + entry.cy * cell
        if x + size / 2 < left or x - size / 2 > right or y + size / 2 < top or y - size / 2 > bottom then
            hideItem(entry)
        else
            entry.widget:setRect({ x = floor(x - size / 2), y = floor(y - size / 2), width = size, height = size })
            if entry.size ~= size then
                entry.size = size
                entry.widget:setIconRect({ x = 0, y = 0, width = size, height = size })
            end
            showItem(entry)
        end
    end
end

-- zoom and offset that show the whole tree
local function fit()
    local tree = state.drawn
    if not tree then
        return
    end
    local canvas = talentsWindow.canvas
    local width, height = canvas:getWidth(), canvas:getHeight()
    state.pendingFit = false
    if width < 50 or height < 50 then
        -- the window was not laid out yet: fit again as soon as the canvas has a size
        state.pendingFit = true
        width, height = 720, 480
    end
    local minX, minY, maxX, maxY = 0, 0, 0, 0
    for _, entry in pairs(state.entries) do
        minX, maxX = math.min(minX, entry.cx - entry.d / 2), math.max(maxX, entry.cx + entry.d / 2)
        minY, maxY = math.min(minY, entry.cy - entry.d / 2), math.max(maxY, entry.cy + entry.d / 2)
    end
    local cell = math.min((width - 20) / math.max(1, maxX - minX), (height - 20) / math.max(1, maxY - minY))
    cell = math.max(MIN_CELL, math.min(MAX_CELL, cell))
    state.cell[tree] = cell
    state.offset[tree] = { x = width / 2 - (minX + maxX) / 2 * cell, y = height / 2 - (minY + maxY) / 2 * cell }
    reposition()
end

function center()
    fit()
end

-- painting -------------------------------------------------------------------------------------------------------

local function paintState(tree)
    if state.drawn ~= tree then
        return
    end
    local current = state.states[tree]
    local level = playerLevel()
    for _, entry in pairs(state.entries) do
        local node, widget = entry.node, entry.widget
        local status, rank = nodeState(tree, node)
        local kind = kindOf(node)
        local color = entry.color
        local fill, ring, opacity
        if status == 'owned' then
            fill, ring, opacity = color, mix(color, '#ffffff', 0.65), 1
        elseif status == 'available' then
            fill, ring, opacity = kind[3] and BG or mix(color, BG, 0.35), GOLD, 1
        else
            fill, ring, opacity = kind[3] and BG or mix(color, BG, kind[5]), color, 0.5
        end
        widget:setImageColor(fill)
        widget:setIconColor(ring)
        widget:setOpacity(opacity)
        widget:setText((node.maxRank or 0) > 1 and rank > 0 and tostring(rank) or '')
        widget:setTooltip(tooltip(node, status, rank, level))
    end
    for _, seg in ipairs(state.segs) do
        if seg.from then
            local owned = isOwned(state.entries[seg.from].node, current) and isOwned(state.entries[seg.to].node, current)
            seg.widget:setBackgroundColor(owned and LINK.owned or LINK.other)
        end
    end
    talentsWindow.points:setText(tr('Free points: %d', current.free))
    -- second currency (class tree): only when the server sends it
    local classPoints = current.classPoints or current.classFree
    if type(classPoints) == 'number' then
        talentsWindow.classPoints:setText(tr('Class points: %d', classPoints))
    else
        talentsWindow.classPoints:setText('')
    end
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

local function addSegment(canvas, style, ax, ay, bx, by, thickness, minPx)
    local widget = g_ui.createWidget(style, canvas)
    widget:setVisible(false)
    widget:setRotation(math.deg(math.atan2(by - ay, bx - ax)))
    local seg = { widget = widget, ax = ax, ay = ay, bx = bx, by = by, len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2),
        th = thickness, minPx = minPx, shown = false }
    table.insert(state.segs, seg)
    return seg
end

-- dashed hexagon outlines + labels of the level bands (only in the new tree)
local function addBands(canvas, layout)
    local bands = BANDS
    if layout.faixas then
        bands = {}
        for _, band in ipairs(layout.faixas) do
            local level = band.nivel or band.level
            table.insert(bands, { level = level, radius = band.raio or band.radius, color = BAND_COLORS[level] or '#ffffff' })
        end
    end
    for _, band in ipairs(bands) do
        local radius = band.radius
        local vertices = {}
        for i, angle in ipairs(HEX_ANGLES) do
            vertices[i] = { radius * math.cos(math.rad(angle)), radius * math.sin(math.rad(angle)) }
        end
        for i = 1, #vertices do
            local a, b = vertices[i], vertices[i % #vertices + 1]
            local dx, dy = (b[1] - a[1]) / radius, (b[2] - a[2]) / radius -- unit vector along the edge (length = radius)
            for start = 0, radius - 1, DASH_PERIOD do
                local stop = math.min(start + DASH_LENGTH, radius)
                local seg = addSegment(canvas, 'TalentDash', a[1] + dx * start, a[2] + dy * start, a[1] + dx * stop,
                    a[2] + dy * stop, 0.45, 2)
                seg.widget:setBackgroundColor(band.color)
                seg.widget:setOpacity(0.55)
            end
        end
        local label = g_ui.createWidget('TalentBandLabel', canvas)
        label:setText('LEVEL ' .. band.level)
        label:setColor(band.color)
        label:setOpacity(0.85)
        label:setVisible(false)
        table.insert(state.labels, { widget = label, cx = 0, cy = -radius * math.cos(math.rad(30)) - 2.5, shown = false })
    end
end

local function draw(tree)
    local layout = state.layouts[tree]
    local canvas = talentsWindow.canvas
    -- keep nothing: the hint label is outside the canvas
    for _, child in ipairs(canvas:getChildren()) do
        child:destroy()
    end
    state.entries, state.segs, state.labels, state.drawn = {}, {}, {}, tree
    talentsWindow:setText(layout.name)
    talentsWindow.talentTab:setOn(tree == 'talent')
    talentsWindow.paragonTab:setOn(tree == 'paragon')

    local scale = scaleOf(tree)
    local newTree = layout.faixas ~= nil
    for _, node in ipairs(layout.nodes) do
        if node.kind == 'travessia' then
            newTree = true
            break
        end
    end
    if tree == 'talent' and newTree then
        addBands(canvas, layout)
    end
    -- links before the nodes, so the nodes are drawn over them; each pair once
    local seen = {}
    for _, node in ipairs(layout.nodes) do
        for _, other in ipairs(node.links) do
            local target = layout.byId[other]
            local key = node.id < other and (node.id .. '|' .. other) or (other .. '|' .. node.id)
            if target and not seen[key] then
                seen[key] = true
                local travel = node.kind == 'travessia' and target.kind == 'travessia'
                local seg = addSegment(canvas, 'TalentLink', node.x * scale, node.y * scale, target.x * scale,
                    target.y * scale, travel and 0.57 or 0.4, 1)
                seg.from, seg.to = node.id, other
            end
        end
    end
    for _, node in ipairs(layout.nodes) do
        local kind = kindOf(node)
        local widget = g_ui.createWidget('TalentNode', canvas)
        local square = kind[2] == 'square'
        widget:setImageSource(IMG .. (square and 'square' or 'disc'))
        widget:setIcon(IMG .. (square and 'square_ring' or 'ring'))
        widget:setVisible(false)
        local nodeId = node.id
        widget.onClick = function()
            send(string.format('buy:%s:%s', state.tree, nodeId))
        end
        state.entries[node.id] = { node = node, widget = widget, cx = node.x * scale, cy = node.y * scale, d = kind[1],
            color = nodeColor(node), shown = false }
    end
    if not state.offset[tree] then
        fit()
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
    -- the window moved or was resized: the widgets use absolute positions
    canvas.onGeometryChange = function()
        if state.pendingFit and canvas:getWidth() >= 50 and canvas:getHeight() >= 50 then
            fit()
        else
            reposition()
        end
    end
    canvas.onMouseWheel = function(self, mousePos, direction)
        local tree = state.drawn
        if not tree then
            return false
        end
        local old = state.cell[tree]
        local new = math.max(MIN_CELL, math.min(MAX_CELL, direction == MouseWheelUp and old * ZOOM_STEP or old / ZOOM_STEP))
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
    state.entries, state.segs, state.labels, state.cell = {}, {}, {}, {}
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
