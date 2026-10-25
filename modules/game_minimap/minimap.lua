local iconTopMenu = nil
-- @ Minimap
local minimapWidget = nil -- bot fix
local otmm = true
local oldPos = nil
local fullscreenWidget
local virtualFloor = 7

local function onPositionChange()
    local player = g_game.getLocalPlayer()
    if not player then
        return
    end

    local pos = player:getPosition()
    if not pos then
        return
    end

    local minimapWidget = mapController.ui.minimapBorder.minimap
    if not (minimapWidget) or minimapWidget:isDragging() then
        return
    end

    if not minimapWidget.fullMapView then
        minimapWidget:setCameraPosition(pos)
    end

    minimapWidget:setCrossPosition(pos)
    virtualFloor = pos.z
end

mapController = Controller:new()
mapController:setUI('minimap', modules.game_interface.getMainRightPanel())

-- extended view: while the title bar is dragged, a translucent box shows where the minimap will land
local dropGhost = nil

local function sideAt(mousePos)
    return mousePos.x < rootWidget:getWidth() / 2 and 'left' or 'right'
end

local function placeDropGhost(side)
    local gameRoot = modules.game_interface.getRootPanel()
    local holder = modules.game_interface.getExtendedMinimapHolder()
    local width, height = holder:getWidth(), holder:getHeight()
    local x = side == 'left' and gameRoot:getX() or gameRoot:getX() + gameRoot:getWidth() - width
    dropGhost:setRect({ x = x, y = holder:getY(), width = width, height = height })
end

local function destroyDropGhost()
    if dropGhost then
        dropGhost:destroy()
        dropGhost = nil
    end
end

function mapController:onInit()
    local dragHandle = self.ui:getChildById('dragHandle')
    dragHandle.onDragEnter = function(widget, mousePos)
        destroyDropGhost()
        dropGhost = g_ui.createWidget('UIWidget', rootWidget)
        dropGhost:setPhantom(true)
        dropGhost:setBackgroundColor('#ffffff18')
        dropGhost:setBorderWidth(1)
        dropGhost:setBorderColor('#ffffff80')
        placeDropGhost(sideAt(mousePos))
        return true
    end
    dragHandle.onDragMove = function(widget, mousePos, mouseMoved)
        if dropGhost then
            placeDropGhost(sideAt(mousePos))
        end
        return true
    end
    dragHandle.onDragLeave = function(widget, droppedWidget, mousePos)
        destroyDropGhost()
        modules.game_interface.setMinimapSide(sideAt(mousePos))
        return true
    end
end

function mapController:onGameStart()
    mapController:registerEvents(LocalPlayer, {
        onPositionChange = onPositionChange
    }):execute()

    -- Load Map
    g_minimap.clean()

    local minimapFile = '/minimap'
    local loadFnc = nil

    if otmm then
        minimapFile = minimapFile .. '.otmm'
        loadFnc = g_minimap.loadOtmm
    else
        minimapFile = minimapFile .. '_' .. g_game.getClientVersion() .. '.otcm'
        loadFnc = g_map.loadOtcm
    end

    -- data/minimap.otmm is the whole map, already explored (tools/gen_minimap.py); a player's own file is a subset
    -- of it, and loading it afterwards would replace whole blocks with partly unseen ones
    if otmm and g_resources.fileExists('/data/minimap.otmm') then
        loadFnc('/data/minimap.otmm')
    elseif g_resources.fileExists(minimapFile) then
        loadFnc(minimapFile)
    end

    self.ui.minimapBorder.minimap:load()
end

function mapController:onGameEnd()
    -- Save Map
    if otmm then
        g_minimap.saveOtmm('/minimap.otmm')
    else
        g_map.saveOtcm('/minimap_' .. g_game.getClientVersion() .. '.otcm')
    end

    self.ui.minimapBorder.minimap:save()
end

function mapController:onTerminate()
    destroyDropGhost()
    if iconTopMenu then
        iconTopMenu:destroy()
        iconTopMenu = nil
    end
end

function zoomIn()
    mapController.ui.minimapBorder.minimap:zoomIn()
end

function zoomOut()
    mapController.ui.minimapBorder.minimap:zoomOut()
end

function openCyclopediaMap()
    return fullscreen()
end

function fullscreen()
    local minimapWidget = mapController.ui.minimapBorder.minimap
    if not minimapWidget then
        minimapWidget = fullscreenWidget
    end
    local zoom;

    if not minimapWidget then
        return
    end

    if minimapWidget.fullMapView then
        fullscreenWidget = nil
        minimapWidget:setParent(mapController.ui.minimapBorder)
        minimapWidget:fill('parent')
        mapController.ui:show()
        zoom = minimapWidget.zoomMinimap
        g_keyboard.unbindKeyDown('Escape')
        minimapWidget.fullMapView = false
    else
        fullscreenWidget = minimapWidget
        mapController.ui:hide(true)
        minimapWidget:setParent(modules.game_interface.getRootPanel())
        minimapWidget:fill('parent')
        zoom = minimapWidget.zoomFullmap
        g_keyboard.bindKeyDown('Escape', fullscreen)
        minimapWidget.fullMapView = true
    end

    local pos = oldPos or minimapWidget:getCameraPosition()
    oldPos = minimapWidget:getCameraPosition()
    minimapWidget:setZoom(zoom)
    minimapWidget:setCameraPosition(pos)
end

function upLayer()
    if virtualFloor == 0 then
        return
    end

    mapController.ui.minimapBorder.minimap:floorUp(1)
    virtualFloor = virtualFloor - 1
end

function downLayer()
    if virtualFloor == 15 then
        return
    end

    mapController.ui.minimapBorder.minimap:floorDown(1)
    virtualFloor = virtualFloor + 1
end

function onClickRoseButton(dir)
    if dir == 'north' then
        mapController.ui.minimapBorder.minimap:move(0, 1)
    elseif dir == 'north-east' then
        mapController.ui.minimapBorder.minimap:move(-1, 1)
    elseif dir == 'east' then
        mapController.ui.minimapBorder.minimap:move(-1, 0)
    elseif dir == 'south-east' then
        mapController.ui.minimapBorder.minimap:move(-1, -1)
    elseif dir == 'south' then
        mapController.ui.minimapBorder.minimap:move(0, -1)
    elseif dir == 'south-west' then
        mapController.ui.minimapBorder.minimap:move(1, -1)
    elseif dir == 'west' then
        mapController.ui.minimapBorder.minimap:move(1, 0)
    elseif dir == 'north-west' then
        mapController.ui.minimapBorder.minimap:move(1, 1)
    end
end

function resetMap()
    mapController.ui.minimapBorder.minimap:reset()
    local player = g_game.getLocalPlayer()
    if player then
        virtualFloor = player:getPosition().z
    end
end

function getMiniMapUi()
    return mapController.ui.minimapBorder.minimap
end

function extendedView(extendedView)
    if extendedView then
        if not iconTopMenu then
            iconTopMenu = modules.client_topmenu.addTopRightToggleButton('miniMap', tr('Show miniMap'),
                '/images/topbuttons/minimap', toggle)
            iconTopMenu:setOn(mapController.ui:isVisible())
        end
        local holder = modules.game_interface.getExtendedMinimapHolder()
        mapController.ui:setParent(holder)
        mapController.ui:fill('parent')
        mapController.ui:getChildById('dragHandle'):show()
        mapController.ui.minimapBorder:addAnchor(AnchorTop, 'dragHandle', AnchorBottom)
        -- only the drag handle moves it here; dragging the window itself would drop it into a column
        mapController.ui:setDraggable(false)
    else
        if iconTopMenu then
            iconTopMenu:destroy()
            iconTopMenu = nil
        end
        mapController.ui:setBorderColor('alpha')
        mapController.ui:setBorderWidth(0)
        mapController.ui:breakAnchors()
        mapController.ui:getChildById('dragHandle'):hide()
        mapController.ui.minimapBorder:addAnchor(AnchorTop, 'parent', AnchorTop)
        mapController.ui:setDraggable(true)
        mapController.ui:setHeight(mapController.ui.panelHeight)
        local mainRightPanel = modules.game_interface.getMainRightPanel()
        if not mainRightPanel:hasChild(mapController.ui) then
            mainRightPanel:insertChild(1, mapController.ui)
        end
        mapController.ui:show()

    end
    mapController.ui.moveOnlyToMain = not extendedView
end

function toggle()
    if iconTopMenu:isOn() then
        mapController.ui:hide()
        iconTopMenu:setOn(false)
    else
        mapController.ui:show()
        iconTopMenu:setOn(true)
    end
    modules.game_interface.setExtendedMinimapVisible(iconTopMenu:isOn())
end
