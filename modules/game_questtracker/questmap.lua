-- Quest places on the full map (design/quest-tracker.md, section 12.2). A place is a named hunting ground with no
-- floor in its text ("Dragon Lair (Venore)"): it is drawn as the cells that have a spawn (the shape of the ground, not
-- a rectangle over the sea), on whatever floor the map shows, with a small list (quest, place, monsters).
-- Drawn only on the full map (the minimap does not clip its children): every tracked quest in progress, each in its
-- own colour, plus the quest of a place clicked in the journal (the map opens on it, on its floor).
-- The shapes come from the server's "mapplaces" (asked with "map" when the full map opens); until then a quest shows
-- the rectangles its view carries.
local CELL_STYLE = 'QuestPlaceCell'
local AREA_STYLE = 'QuestPlaceArea'
local LABEL_STYLE = 'QuestPlaceLabel'

-- strong hues that read over the green and blue of the map (user, 2026-10-26: red, orange, purple...)
local HUES = { 'ff3b30', 'ff9500', 'af52de', 'ff2d92', 'ffd60a', 'c0392b', 'e67e22', '8e44ad' }
-- the server answers one "map" per second: asked again no sooner than this
local MAP_REQUEST_INTERVAL = 1200

local minimap = nil
local overlays = {}
local focusQuest = nil -- the quest of the place clicked in the journal (drawn even if not tracked)
local mapPlaces = {}   -- quest id -> places with their cells (from "mapplaces")
local lastFloor = nil
local lastFull = nil
local redrawEvent = nil
local lastMapRequest = 0
local mapRequestEvent = nil

local onCameraPositionChange
local onGeometryChange

-- found on first use (the minimap may not exist yet when this module loads); the same widget goes full screen
local function findMinimap()
    if minimap and not minimap:isDestroyed() then
        return minimap
    end
    local controller = modules.game_minimap and modules.game_minimap.mapController
    local ui = controller and controller.ui
    local border = ui and ui.minimapBorder
    minimap = border and border:getChildById('minimap') or nil
    if minimap then
        connect(minimap, { onCameraPositionChange = onCameraPositionChange, onGeometryChange = onGeometryChange })
    end
    return minimap
end

local function clearOverlays()
    for _, widget in ipairs(overlays) do
        if not widget:isDestroyed() then
            widget:destroy()
        end
    end
    overlays = {}
end

-- a rectangle of tiles (from/to) or a point (a label), on the floor the map shows now
local function anchor(map, widget)
    local z = map:getCameraPosition().z
    widget:breakAnchors()
    if widget.center then
        map:centerInPosition(widget, { x = widget.center.x, y = widget.center.y, z = z })
        return
    end
    local topLeft = { x = widget.from.x, y = widget.from.y, z = z }
    local bottomRight = { x = widget.to.x, y = widget.to.y, z = z }
    map:anchorPosition(widget, AnchorLeft, topLeft, AnchorLeft)
    map:anchorPosition(widget, AnchorTop, topLeft, AnchorTop)
    map:anchorPosition(widget, AnchorRight, bottomRight, AnchorRight)
    map:anchorPosition(widget, AnchorBottom, bottomRight, AnchorBottom)
end

local function add(map, style, hue, from, to, center)
    local widget = g_ui.createWidget(style)
    if hue and style ~= LABEL_STYLE then
        widget:setBackgroundColor('#' .. hue .. '80')
        if style == AREA_STYLE then
            widget:setBorderColor('#' .. hue .. 'e0')
        end
    end
    -- areas under everything of the map (cross, flags, buttons); labels over the areas
    if style == LABEL_STYLE then
        map:addChild(widget)
    else
        map:insertChild(1, widget)
    end
    widget.from, widget.to, widget.center = from, to, center
    anchor(map, widget)
    overlays[#overlays + 1] = widget
    return widget
end

-- "48  Minotaur" per monster under the place name (the quest name first, in its colour, when several are drawn)
function placeList(place, label)
    local lines = { place.name }
    if place.monsters and #place.monsters > 0 then
        for _, monster in ipairs(place.monsters) do
            lines[#lines + 1] = string.format('%d  %s', monster.count or 0, monster.name or label or '?')
        end
    elseif place.count and label then
        lines[#lines + 1] = string.format('%d  %s', place.count, label)
    end
    return table.concat(lines, '\n')
end

-- "East of Thais - Minotaur: 40, Minotaur Archer: 29" (the journal's Hints), or just the name (an NPC, an area)
function placeText(place, label)
    if place.monsters and #place.monsters > 0 then
        local parts = {}
        for _, monster in ipairs(place.monsters) do
            parts[#parts + 1] = string.format('%s: %d', monster.name or label or '?', monster.count or 0)
        end
        return place.name .. ' - ' .. table.concat(parts, ', ')
    elseif place.count and label then
        return string.format('%s - %s: %d', place.name, label, place.count)
    end
    return place.name
end

-- the places of a quest: the shapes from "mapplaces", or the rectangles of its view until they arrive
local function placesOf(id)
    if mapPlaces[id] then
        return mapPlaces[id]
    end
    local view = quests[id]
    local list = {}
    if not view or view.mystery or view.state ~= 'active' or not view.stage then
        return list
    end
    for _, objective in ipairs(view.stage.objectives or {}) do
        if not objective.done then
            for _, place in ipairs(objective.places or {}) do
                list[#list + 1] = place
            end
        end
    end
    for _, place in ipairs(view.stage.places or {}) do
        list[#list + 1] = place
    end
    return list
end

local function drawArea(map, place, hue)
    local size = place.cell
    if place.cells and size and #place.cells > 0 then
        for i = 1, #place.cells, 2 do
            local x, y = place.cells[i] * size, place.cells[i + 1] * size
            add(map, CELL_STYLE, hue, { x = x, y = y }, { x = x + size - 1, y = y + size - 1 })
        end
    else
        add(map, AREA_STYLE, hue, place.from, place.to)
    end
end

local function drawLabel(map, place, hue, questName)
    local center = { x = math.floor((place.from.x + place.to.x) / 2), y = math.floor((place.from.y + place.to.y) / 2) }
    local label = add(map, LABEL_STYLE, hue, nil, nil, center)
    local text = placeList(place)
    if questName then
        text = questName .. '\n' .. text
    end
    label:setText(text)
    label:setBorderColor('#' .. hue)
end

function redrawPlaces()
    local map = findMinimap()
    if not map then
        return
    end
    clearOverlays()
    lastFloor = map:getCameraPosition().z
    lastFull = map.fullMapView
    if not map.fullMapView then
        return
    end
    -- every tracked quest in progress, and the one clicked in the journal; one colour each
    local drawn = {}
    for _, id in ipairs(questOrder) do
        local view = quests[id]
        if view and view.state == 'active' and not view.mystery and (isTracked(id) or id == focusQuest) then
            drawn[#drawn + 1] = id
        end
    end
    -- every area first, then every label on top
    for index, id in ipairs(drawn) do
        for _, place in ipairs(placesOf(id)) do
            drawArea(map, place, HUES[(index - 1) % #HUES + 1])
        end
    end
    for index, id in ipairs(drawn) do
        for _, place in ipairs(placesOf(id)) do
            drawLabel(map, place, HUES[(index - 1) % #HUES + 1], #drawn > 1 and quests[id].name or nil)
        end
    end
end

-- after a burst of quest changes, once
function scheduleRedrawPlaces()
    if redrawEvent then
        return
    end
    redrawEvent = scheduleEvent(function()
        redrawEvent = nil
        redrawPlaces()
    end, 100)
end

-- the shapes of every quest in progress; at most one request per MAP_REQUEST_INTERVAL (the last one is kept)
function requestMapPlaces()
    if mapRequestEvent then
        return
    end
    local wait = math.max(0, lastMapRequest + MAP_REQUEST_INTERVAL - g_clock.millis())
    mapRequestEvent = scheduleEvent(function()
        mapRequestEvent = nil
        lastMapRequest = g_clock.millis()
        local protocol = g_game.getProtocolGame()
        if protocol then
            protocol:sendExtendedOpcode(OPCODE, 'map')
        end
    end, wait)
end

-- answer to "map": the places of one quest, with their shape
function onMapPlaces(data)
    if type(data.quest) == 'string' and type(data.places) == 'table' then
        mapPlaces[data.quest] = data.places
        scheduleRedrawPlaces()
    end
end

-- answer to "places" (older request): the same shapes, for one objective
function onPlacesMessage(data)
end

-- the floor the map shows changed, or the map went full screen (or back)
onCameraPositionChange = function(widget, position)
    if not position then
        return
    end
    if widget.fullMapView ~= lastFull then
        lastFull = widget.fullMapView
        if widget.fullMapView then
            requestMapPlaces()
        end
        redrawPlaces()
    elseif position.z ~= lastFloor then
        lastFloor = position.z
        for _, overlay in ipairs(overlays) do
            if not overlay:isDestroyed() then
                anchor(widget, overlay)
            end
        end
    end
end

-- the map changes size when it goes full screen (or back), even when the camera does not move
onGeometryChange = function(widget)
    if widget.fullMapView ~= lastFull then
        onCameraPositionChange(widget, widget:getCameraPosition())
    end
end

-- a place clicked in the journal: the full map opens on it, on its floor, with its quest drawn
function showPlaces(questId, clicked)
    local map = findMinimap()
    if not map then
        return
    end
    focusQuest = questId
    if not map.fullMapView and modules.game_minimap.fullscreen then
        modules.game_minimap.fullscreen()
    end
    if clicked then
        map:setCameraPosition({
            x = math.floor((clicked.from.x + clicked.to.x) / 2),
            y = math.floor((clicked.from.y + clicked.to.y) / 2),
            -- the floor the player is looking at: the minimap is black on floors not explored yet
            z = map:getCameraPosition().z
        })
    end
    requestMapPlaces()
    redrawPlaces()
end

-- the quest data changed: the shapes are asked again next time the full map opens (or now, if it is open)
function onQuestsChanged()
    mapPlaces = {}
    local map = findMinimap()
    if map and map.fullMapView then
        requestMapPlaces()
    end
    scheduleRedrawPlaces()
end

function clearPlacesFocus()
    focusQuest = nil
    scheduleRedrawPlaces()
end

function initPlaces()
    g_ui.importStyle('questmap')
end

function terminatePlaces()
    if redrawEvent then
        removeEvent(redrawEvent)
        redrawEvent = nil
    end
    if mapRequestEvent then
        removeEvent(mapRequestEvent)
        mapRequestEvent = nil
    end
    if minimap and not minimap:isDestroyed() then
        disconnect(minimap, { onCameraPositionChange = onCameraPositionChange, onGeometryChange = onGeometryChange })
    end
    clearOverlays()
    focusQuest = nil
    mapPlaces = {}
    minimap = nil
end
