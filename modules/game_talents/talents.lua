-- Talent and paragon trees (server opcode 123, forgottenserver data/scripts/lib/talents.lua).
-- The server sends each node with its grid position, rank and whether it can be learned; the window draws the nodes
-- on a canvas with lines from each prerequisite and buys a node on click (the server checks everything again).
local OPCODE = 123
local COLUMN_WIDTH = 140
local ROW_HEIGHT = 70
local MARGIN = 14
local LINK_WIDTH = 2
local RESULT_COLORS = { ok = '#7fd77f', error = '#e06060' }
local BORDER = { learned = '#d8b03c', available = '#3c8d3c', blocked = '#4a4a4a' }
local LINK = { learned = '#d8b03c', other = '#5a5a5a' }

talentsWindow = nil
local talentsButton = nil
local currentTree = 'talent'

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

local function nodeState(node)
    if node.blocked == '' then
        return 'available'
    end
    return node.rank > 0 and 'learned' or 'blocked'
end

-- offset of a node inside the canvas
local function nodeRect(node)
    return { x = math.floor(MARGIN + node.x * COLUMN_WIDTH), y = math.floor(MARGIN + node.y * ROW_HEIGHT) }
end

-- children are anchored to the canvas corner with margins, so they follow the window when it moves
local function place(widget, rect)
    widget:addAnchor(AnchorTop, 'parent', AnchorTop)
    widget:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    widget:setMarginTop(rect.y)
    widget:setMarginLeft(rect.x)
    if rect.width then
        widget:setSize({ width = rect.width, height = rect.height })
    end
end

-- an L-shaped line from the bottom of `from` to the top of `to`: down, across, down
local function link(from, to, color)
    local canvas = talentsWindow.canvas
    local a, b = nodeRect(from), nodeRect(to)
    local ax, ay = a.x + 46, a.y + 46
    local bx, by = b.x + 46, b.y
    local midY = math.floor((ay + by) / 2)
    local pieces = {
        { x = ax, y = ay, width = LINK_WIDTH, height = midY - ay },
        { x = math.min(ax, bx), y = midY, width = math.abs(bx - ax) + LINK_WIDTH, height = LINK_WIDTH },
        { x = bx, y = midY, width = LINK_WIDTH, height = by - midY }
    }
    for _, rect in ipairs(pieces) do
        if rect.width > 0 and rect.height > 0 then
            local piece = g_ui.createWidget('TalentLink', canvas)
            place(piece, rect)
            piece:setBackgroundColor(color)
        end
    end
end

local function tooltip(node)
    local lines = { node.name, tr('Each rank: %s', node.text), tr('Cost: %d point(s)', node.cost) }
    if node.maxRank > 0 then
        table.insert(lines, tr('Rank: %d/%d', node.rank, node.maxRank))
    else
        table.insert(lines, tr('Rank: %d (no limit)', node.rank))
    end
    if node.blocked ~= '' then
        table.insert(lines, node.blocked)
    else
        table.insert(lines, tr('Click to learn.'))
    end
    return table.concat(lines, '\n')
end

local function render(data)
    currentTree = data.tree
    talentsWindow:setText(data.name)
    talentsWindow.points:setText(tr('Free points: %d', data.free))
    talentsWindow.talentTab:setOn(data.tree == 'talent')
    talentsWindow.paragonTab:setOn(data.tree == 'paragon')

    local canvas = talentsWindow.canvas
    canvas:destroyChildren()

    local byId = {}
    for _, node in ipairs(data.nodes) do
        byId[node.id] = node
    end

    -- lines first, so the nodes are drawn over them
    for _, node in ipairs(data.nodes) do
        for _, requiredId in ipairs(node.requires) do
            local required = byId[requiredId]
            if required then
                link(required, node, required.rank > 0 and LINK.learned or LINK.other)
            end
        end
    end

    for _, node in ipairs(data.nodes) do
        local widget = g_ui.createWidget('TalentNode', canvas)
        place(widget, nodeRect(node))
        widget:setText(node.name)
        widget.rank:setText(node.maxRank > 0 and string.format('%d/%d', node.rank, node.maxRank) or tostring(node.rank))
        local state = nodeState(node)
        widget:setBorderColor(BORDER[state])
        -- nodes stay opaque so the connector lines pass behind them; a blocked node only dims its text
        widget:setColor(state == 'blocked' and '#7a7a7a' or '#dfdfdf')
        widget:setTooltip(tooltip(node))
        local nodeId = node.id
        widget.onClick = function()
            send(string.format('buy:%s:%s', currentTree, nodeId))
        end
    end
end

local function onMessage(protocol, opcode, data)
    if not talentsWindow or type(data) ~= 'table' then
        return
    end
    if data.action == 'tree' then
        render(data)
    elseif data.action == 'result' then
        setResult(data.status, data.message)
    end
end

function open(tree)
    setResult(nil, '')
    send('open:' .. tree)
end

function show()
    talentsWindow:show()
    talentsWindow:raise()
    talentsWindow:focus()
    open(currentTree)
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
    if talentsWindow then
        talentsWindow.canvas:destroyChildren()
    end
end

function init()
    talentsWindow = g_ui.displayUI('talents')
    talentsWindow:hide()
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
