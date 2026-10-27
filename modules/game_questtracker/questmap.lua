-- Quest places on the minimap and on the full map (design/quest-tracker.md, section 12.2). A place is a named
-- rectangle with no floor ("Dragon Lair (Venore)"): it is drawn on whatever floor the map shows, as one patch over
-- the whole area, never the spawn spots. Drawn: the places of the tracked quests (current stage), a "!" where an
-- available quest starts (one per spot, the names in the tooltip), and the places the journal asked to see.
local AREA_STYLE = 'QuestPlaceArea'
local FOCUS_STYLE = 'QuestPlaceFocus'
local START_STYLE = 'QuestPlaceStart'

local minimap = nil
local overlays = {}
local focus = nil      -- { quest, objective, places } shown from the journal
local lastFloor = nil
local lastFull = nil
local redrawEvent = nil

local onCameraPositionChange

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
        connect(minimap, { onCameraPositionChange = onCameraPositionChange })
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

-- the rectangle on the floor the map shows now
local function anchor(map, widget)
    local z = map:getCameraPosition().z
    widget:breakAnchors()
    local place = widget.place
    if widget.isStart then
        local center = { x = math.floor((place.from.x + place.to.x) / 2), y = math.floor((place.from.y + place.to.y) / 2), z = z }
        map:centerInPosition(widget, center)
        return
    end
    -- names only on the full map: on the small minimap they would cover each other
    local label = widget:getChildById('name')
    if label then
        label:setVisible(map.fullMapView == true)
    end
    local topLeft = { x = place.from.x, y = place.from.y, z = z }
    local bottomRight = { x = place.to.x, y = place.to.y, z = z }
    map:anchorPosition(widget, AnchorLeft, topLeft, AnchorLeft)
    map:anchorPosition(widget, AnchorTop, topLeft, AnchorTop)
    map:anchorPosition(widget, AnchorRight, bottomRight, AnchorRight)
    map:anchorPosition(widget, AnchorBottom, bottomRight, AnchorBottom)
end

local function addOverlay(map, style, place, text)
    local widget = g_ui.createWidget(style)
    map:insertChild(1, widget)
    widget.place = place
    widget.isStart = style == START_STYLE
    local label = widget:getChildById('name')
    if label then
        label:setText(text)
        if style == FOCUS_STYLE then
            label:setColor('#cfe4ff')
        end
    else
        widget:setTooltip(text)
    end
    anchor(map, widget)
    overlays[#overlays + 1] = widget
end

-- "Dragon Lair (Venore) - 23 dragons"
function placeText(place, label)
    if place.count and label then
        return string.format('%s - %d %s', place.name, place.count, place.monster or label)
    end
    return place.name
end

local function placesOfView(view)
    local list = {}
    if view.mystery or view.state ~= 'active' or not view.stage then
        return list
    end
    for _, objective in ipairs(view.stage.objectives or {}) do
        if not objective.done then
            for _, place in ipairs(objective.places or {}) do
                list[#list + 1] = { place = place, text = placeText(place, objective.label) }
            end
        end
    end
    for _, place in ipairs(view.stage.places or {}) do
        list[#list + 1] = { place = place, text = place.name }
    end
    return list
end

function redrawPlaces()
    local map = findMinimap()
    if not map then
        return
    end
    clearOverlays()
    lastFloor = map:getCameraPosition().z
    if not showsPlaces() then
        return
    end
    local starts = {}
    for _, id in ipairs(questOrder) do
        local view = quests[id]
        if view and isTracked(id) then
            for _, entry in ipairs(placesOfView(view)) do
                addOverlay(map, AREA_STYLE, entry.place, view.name .. ': ' .. entry.text)
            end
        end
        if view and view.state == 'available' then
            for _, place in ipairs(view.startPlaces or {}) do
                local key = place.from.x .. ':' .. place.from.y
                local spot = starts[key]
                if not spot then
                    spot = { place = place, names = {} }
                    starts[key] = spot
                end
                spot.names[#spot.names + 1] = view.name
            end
        end
    end
    for _, spot in pairs(starts) do
        local names = spot.names
        local text = #names > 6 and string.format('%s and %d more', table.concat(names, ', ', 1, 6), #names - 6) or
            table.concat(names, ', ')
        addOverlay(map, START_STYLE, spot.place, tr('Quests here: %s', text))
    end
    if focus then
        for _, place in ipairs(focus.places) do
            addOverlay(map, FOCUS_STYLE, place, placeText(place, focus.label))
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

-- the floor the map shows changed (or the map went full screen): every patch moves to it
onCameraPositionChange = function(widget, position)
    if position and (position.z ~= lastFloor or widget.fullMapView ~= lastFull) then
        lastFull = widget.fullMapView
        lastFloor = position.z
        for _, overlay in ipairs(overlays) do
            if not overlay:isDestroyed() then
                anchor(widget, overlay)
            end
        end
    end
end

-- the journal asks to see the places of an objective: the full map opens on the clicked one, with all of them
function showPlaces(questId, objectiveIndex, places, clicked, label, more)
    local map = findMinimap()
    if not map then
        return
    end
    focus = { quest = questId, objective = objectiveIndex, places = places, label = label }
    if not map.fullMapView and modules.game_minimap.fullscreen then
        modules.game_minimap.fullscreen()
    end
    if clicked then
        map:setCameraPosition({
            x = math.floor((clicked.from.x + clicked.to.x) / 2),
            y = math.floor((clicked.from.y + clicked.to.y) / 2),
            z = map:getCameraPosition().z
        })
    end
    redrawPlaces()
    -- the view carries the biggest places only: ask for all of them
    if more and objectiveIndex then
        local protocol = g_game.getProtocolGame()
        if protocol then
            protocol:sendExtendedOpcode(OPCODE, string.format('places %s %d', questId, objectiveIndex))
        end
    end
end

-- answer to "places": every place of the objective in focus
function onPlacesMessage(data)
    if focus and data.quest == focus.quest and data.objective == focus.objective and type(data.places) == 'table' then
        focus.places = data.places
        redrawPlaces()
    end
end

function clearPlacesFocus()
    focus = nil
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
    if minimap and not minimap:isDestroyed() then
        disconnect(minimap, { onCameraPositionChange = onCameraPositionChange })
    end
    clearOverlays()
    focus = nil
    minimap = nil
end
