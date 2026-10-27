-- Quest places on the map and the quest GPS (design/quest-tracker.md, section 12.2). A place is a name, a kind and one
-- marker (user, 2026-10-27: no heat map, no counts): a cave at its entrance (skull), an open ground at its centre
-- (sword), an NPC where it stands. Only the place the player picks is marked, with the minimap's own flags (seen on
-- the minimap and on the full map, never saved). The GPS points to it: an arrow at the top of the game screen with
-- the name and the distance, like the WoW quest helper; it goes away on arrival.
local FLAG_ICON = { cave = 12, area = 7, npc = 6 }
local ARRIVED = 4         -- squares from the marker that count as there
local ARRIVED_LINGER = 3000
local GPS_INTERVAL = 250

local minimap = nil
local target = nil        -- { quest, place = {name, kind, marker} }
local flag = nil          -- position of the flag set for the target
local gps = nil           -- the arrow widget
local gpsEvent = nil
local arrivedEvent = nil

-- found on first use (the minimap may not exist yet when this module loads); the same widget goes full screen
local function findMinimap()
    if minimap and not minimap:isDestroyed() then
        return minimap
    end
    local controller = modules.game_minimap and modules.game_minimap.mapController
    local ui = controller and controller.ui
    local border = ui and ui.minimapBorder
    minimap = border and border:getChildById('minimap') or nil
    return minimap
end

-- the Hints line of a place: just its name ("Troll Cave (Carlin)", "Cyclopolis (Edron)", "Kazzan (Darashia)")
function placeText(place)
    return place.name
end

-- the GPS's own flags: the widget it made is kept and destroyed itself (never a flag of the player on the same tile,
-- and nothing to do if the player already deleted it with right click > Delete mark)
local function addOwnFlag(position, icon, description)
    local map = findMinimap()
    if not map or map:getFlag(position) then
        return nil
    end
    map:addFlag(position, icon, description, true)
    return map:getFlag(position)
end

local function removeOwnFlag(widget)
    if widget and not widget:isDestroyed() then
        widget:destroy()
    end
    return nil
end

local function clearFlag()
    flag = removeOwnFlag(flag)
end

local function setFlag(place)
    clearFlag()
    if not place.marker then
        return
    end
    flag = addOwnFlag({ x = place.marker.x, y = place.marker.y, z = place.marker.z }, FLAG_ICON[place.kind] or 2, place.name)
end

-- the way to the marker, from the server ("route"): walk legs with points to follow and travel legs (a boat, a
-- carpet: an NPC and what to say). Without a way, the arrow points straight at the marker.
local POINT_REACHED = 3   -- squares from a walk point (same floor) that count as reached
local TRAVELLED = 12      -- squares from where a trip lands that count as having travelled
local OFF_ROUTE = 25      -- farther than this from the point to follow: ask for a new way
local JUMP = 30           -- a move this long between two looks is a trip or a teleport: ask for a new way
local ROUTE_AGAIN = 3000  -- no sooner than this between two asks

local route = nil         -- { legs, leg, point }
local FLOOR_TEXT = {
    up = tr('Go up here'),
    down = tr('Go down here'),
    ladder = tr('Climb the ladder'),
    rope = tr('Use a rope here'),
    sewer = tr('Go down the sewer grate'),
    shovel = tr('Dig here with a shovel')
}
local lastAsk = 0
local lastPosition = nil

local function chebyshev(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

local function askRoute()
    if not target or g_clock.millis() - lastAsk < ROUTE_AGAIN then
        return
    end
    lastAsk = g_clock.millis()
    local protocol = g_game.getProtocolGame()
    local marker = target.place.marker
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, string.format('route %d %d %d', marker.x, marker.y, marker.z))
    end
end

-- answer to "route": the legs to follow (nil: no way, the arrow points straight)
function onRouteMessage(data)
    local marker = target and target.place.marker
    if not marker or type(data.target) ~= 'table' or data.target.x ~= marker.x or data.target.y ~= marker.y then
        return
    end
    route = type(data.legs) == 'table' and #data.legs > 0 and { legs = data.legs, leg = 1, point = 1 } or nil
end

-- where the arrow points now and what it says: the next point of the walk, the NPC of the trip, or the marker
local function aim(position)
    local marker = target.place.marker
    while route and route.legs[route.leg] do
        local leg = route.legs[route.leg]
        if leg.kind == 'floor' then
            -- done once the player is on another floor than the one it is on
            if position.z ~= leg.at.z then
                route.leg, route.point = route.leg + 1, 1
            else
                return leg.at, FLOOR_TEXT[leg.how] or tr('Change floor here')
            end
        elseif leg.kind == 'travel' then
            if chebyshev(position, leg.to) <= TRAVELLED then
                route.leg, route.point = route.leg + 1, 1
            else
                return leg.at, tr('Travel: ask %s for "%s"', leg.npc, leg.keyword)
            end
        else
            local points = leg.points or {}
            -- a point is passed when the player is near it, or when the next one is already nearer: the points are the
            -- middles of the pieces of the way, and walking through a piece seldom touches its middle
            while points[route.point] and points[route.point].z == position.z do
                local here, after = points[route.point], points[route.point + 1]
                local passed = chebyshev(position, here) <= POINT_REACHED or
                    (after and after.z == position.z and chebyshev(position, after) <= chebyshev(position, here))
                if not passed then
                    break
                end
                route.point = route.point + 1
            end
            if points[route.point] then
                if chebyshev(position, points[route.point]) > OFF_ROUTE or points[route.point].z ~= position.z then
                    askRoute()
                end
                -- the last walk goes straight to the marker once its points are done
                return points[route.point], nil
            end
            route.leg, route.point = route.leg + 1, 1
        end
    end
    -- the points of this answer are walked but the marker is not here yet: the rest of the way
    if route and not route.legs[route.leg] and chebyshev(position, marker) > ARRIVED * 4 then
        route = nil
        askRoute()
    end
    return marker, nil
end

-- the next step that is not walking (a floor change, a trip) after the current walk, if any
function upcoming()
    if not route then
        return nil
    end
    for index = route.leg, #route.legs do
        local leg = route.legs[index]
        if leg.kind == 'floor' then
            return leg.at, FLOOR_TEXT[leg.how] or tr('Change floor here')
        elseif leg.kind == 'travel' then
            return leg.at, tr('Travel: ask %s for "%s"', leg.npc, leg.keyword)
        end
    end
    return nil
end

-- the next floor change on the minimap too (an up or down arrow), so the ramp is seen from afar
local STEP_ICON = { up = 14, ladder = 14, rope = 14, down = 15, sewer = 15, shovel = 15 }
local stepFlag = nil
function markUpcoming()
    local map = findMinimap()
    if not map then
        return
    end
    local leg = nil
    for index = route and route.leg or 1, route and #route.legs or 0 do
        if route.legs[index].kind == 'floor' then
            leg = route.legs[index]
            break
        elseif route.legs[index].kind == 'travel' then
            break
        end
    end
    local at = leg and leg.at
    -- the same step: keep its flag (unless the player deleted it)
    if stepFlag and at and stepFlag.at == at then
        return
    end
    -- another step (or none): the flag of the passed one goes
    if stepFlag then
        removeOwnFlag(stepFlag.widget)
        stepFlag = nil
    end
    if at then
        stepFlag = { at = at, widget = addOwnFlag({ x = at.x, y = at.y, z = at.z }, STEP_ICON[leg.how] or 14,
            FLOOR_TEXT[leg.how] or tr('Change floor here')) }
    end
end

-- the arrow: rotated towards where to go now (0 = north, clockwise), the place, the squares and the instruction
local function updateGps()
    if not gps or not target then
        return
    end
    local player = g_game.getLocalPlayer()
    local position = player and player:getPosition()
    local marker = target.place.marker
    if not position or not marker then
        return
    end
    -- a trip or a teleport: the way from here
    if lastPosition and (chebyshev(position, lastPosition) > JUMP or position.z ~= lastPosition.z and not route) then
        askRoute()
    end
    lastPosition = { x = position.x, y = position.y, z = position.z }
    local arrow = gps:getChildById('arrow')
    local text = gps:getChildById('text')
    local distance = chebyshev(position, marker)
    if distance <= ARRIVED and position.z == marker.z then
        arrow:setRotation(0)
        arrow:setVisible(false)
        text:setText(tr('%s\nYou are there.', target.place.name))
        if not arrivedEvent then
            arrivedEvent = scheduleEvent(function()
                arrivedEvent = nil
                stopGuide()
            end, ARRIVED_LINGER)
        end
        return
    end
    local goal, instruction = aim(position)
    local dx, dy = goal.x - position.x, goal.y - position.y
    arrow:setVisible(true)
    arrow:setRotation(math.deg((math.atan2 or math.atan)(dx, -dy)))
    local floors = ''
    if goal == marker and position.z > marker.z then
        floors = ' ' .. tr('(go up)')
    elseif goal == marker and position.z < marker.z then
        floors = ' ' .. tr('(go down)')
    end
    local lines = { target.place.name }
    if instruction then
        lines[#lines + 1] = instruction
        lines[#lines + 1] = string.format('%d %s', chebyshev(position, goal), tr('sqm'))
    else
        lines[#lines + 1] = string.format('%d %s%s', distance, tr('sqm'), floors)
        -- while walking, what comes next (a ramp, a ladder, a boat) and how far: seen before getting there
        local nextAt, nextText = upcoming()
        if nextAt then
            lines[#lines + 1] = tr('Next: %s (%d %s)', nextText, chebyshev(position, nextAt), tr('sqm'))
        end
    end
    text:setText(table.concat(lines, '\n'))
    markUpcoming()
end

function stopGuide()
    target = nil
    route = nil
    markUpcoming()
    route = nil
    lastPosition = nil
    clearFlag()
    if gpsEvent then
        removeEvent(gpsEvent)
        gpsEvent = nil
    end
    if arrivedEvent then
        removeEvent(arrivedEvent)
        arrivedEvent = nil
    end
    if gps then
        gps:hide()
    end
    if refreshMini then
        refreshMini()
    end
end

-- guide to a place: the flag on the map and the arrow on the screen
function guideTo(questId, place)
    if not place or not place.marker then
        return
    end
    stopGuide()
    target = { quest = questId, place = place }
    setFlag(place)
    if not gps then
        local panel = modules.game_interface.getRootPanel()
        if not panel then
            return
        end
        gps = g_ui.createWidget('QuestGps', panel)
        gps:getChildById('close').onClick = stopGuide
    end
    gps:show()
    gps:raise()
    lastAsk = 0
    askRoute()
    updateGps()
    gpsEvent = cycleEvent(updateGps, GPS_INTERVAL)
    if refreshMini then
        refreshMini()
    end
end

function guidedQuest()
    return target and target.quest
end

-- the nearest place of the step a quest is on (the mini window: a click on a quest guides there)
function nearestPlaceOf(view)
    local player = g_game.getLocalPlayer()
    local position = player and player:getPosition()
    local best, distance
    local function consider(place)
        if place.marker then
            local d = position and math.max(math.abs(place.marker.x - position.x), math.abs(place.marker.y - position.y)) or 0
            if not distance or d < distance then
                best, distance = place, d
            end
        end
    end
    if not view or view.mystery or not view.stage then
        return nil
    end
    for _, objective in ipairs(view.stage.objectives or {}) do
        if not objective.done then
            for _, place in ipairs(objective.places or {}) do
                consider(place)
            end
        end
    end
    for _, place in ipairs(view.stage.places or {}) do
        consider(place)
    end
    return best
end

-- a place clicked in the journal: guided, and the full map opens on its marker
function showPlaces(questId, place)
    guideTo(questId, place)
    local map = findMinimap()
    if not map or not place or not place.marker then
        return
    end
    if not map.fullMapView and modules.game_minimap.fullscreen then
        modules.game_minimap.fullscreen()
    end
    map:setCameraPosition({ x = place.marker.x, y = place.marker.y, z = map:getCameraPosition().z })
end

-- the guided quest moved on (stage changed, done): its marker may be gone
function onGuidedQuestChanged(view)
    if not target or not view or view.id ~= target.quest then
        return
    end
    if view.state ~= 'active' then
        stopGuide()
    end
end

-- kept for the messages the server still answers
function redrawPlaces() end
function scheduleRedrawPlaces() end
function onMapPlaces() end
function onPlacesMessage() end
function clearPlacesFocus() end

function initPlaces()
    g_ui.importStyle('questmap')
end

function terminatePlaces()
    stopGuide()
    if gps then
        gps:destroy()
        gps = nil
    end
    minimap = nil
end
