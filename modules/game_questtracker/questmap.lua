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

local function clearFlag()
    local map = findMinimap()
    if map and flag then
        map:removeFlag(flag)
    end
    flag = nil
end

local function setFlag(place)
    clearFlag()
    local map = findMinimap()
    if not map or not place.marker then
        return
    end
    flag = { x = place.marker.x, y = place.marker.y, z = place.marker.z }
    map:addFlag(flag, FLAG_ICON[place.kind] or 2, place.name, true)
end

-- the arrow: rotated towards the marker (0 = north, clockwise), the name and the squares to go
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
    local dx, dy = marker.x - position.x, marker.y - position.y
    local distance = math.max(math.abs(dx), math.abs(dy))
    local arrow = gps:getChildById('arrow')
    local text = gps:getChildById('text')
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
    arrow:setVisible(true)
    arrow:setRotation(math.deg((math.atan2 or math.atan)(dx, -dy)))
    local floors = ''
    if position.z > marker.z then
        floors = ' ' .. tr('(go up)')
    elseif position.z < marker.z then
        floors = ' ' .. tr('(go down)')
    end
    text:setText(string.format('%s\n%d %s%s', target.place.name, distance, tr('sqm'), floors))
end

function stopGuide()
    target = nil
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
