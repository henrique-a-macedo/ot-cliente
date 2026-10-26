-- FloatingPanel: turns a widget into a box that floats over the game. The player drags it anywhere on the screen;
-- right click opens a menu with "Lock position" (a locked box does not move) plus any options the caller adds.
-- Position and lock are saved per box in g_settings ('FloatingPanels' node, keyed by the box name).
FloatingPanel = {}

local SETTINGS_NODE = 'FloatingPanels'

local function loadAll()
    return g_settings.getNode(SETTINGS_NODE) or {}
end

local function saveBox(widget)
    local all = loadAll()
    all[widget.floatingKey] = {
        x = widget:getX() - widget:getParent():getX(),
        y = widget:getY() - widget:getParent():getY(),
        locked = widget.floatingLocked
    }
    g_settings.setNode(SETTINGS_NODE, all)
end

-- keeps the whole box inside its parent
local function place(widget, x, y)
    local parent = widget:getParent()
    local maxX = parent:getX() + parent:getWidth() - widget:getWidth()
    local maxY = parent:getY() + parent:getHeight() - widget:getHeight()
    widget:setPosition({
        x = math.max(parent:getX(), math.min(x, maxX)),
        y = math.max(parent:getY(), math.min(y, maxY))
    })
end

-- moves the box to its saved spot, or to defaultPos ({x, y} relative to the parent) the first time
function FloatingPanel.restore(widget, defaultPos)
    local parent = widget:getParent()
    local saved = loadAll()[widget.floatingKey]
    local rel = saved and saved.x and saved or defaultPos or { x = 0, y = 0 }
    widget:breakAnchors()
    place(widget, parent:getX() + rel.x, parent:getY() + rel.y)
end

function FloatingPanel.isLocked(widget)
    return widget.floatingLocked == true
end

function FloatingPanel.setLocked(widget, locked)
    widget.floatingLocked = locked
    saveBox(widget)
end

-- settingsKey: unique name of the box; menuBuilder(menu), optional, adds the caller's own entries to the menu
function FloatingPanel.attach(widget, settingsKey, menuBuilder)
    widget.floatingKey = settingsKey
    local saved = loadAll()[settingsKey]
    widget.floatingLocked = saved and saved.locked == true or false
    widget:setDraggable(true)
    -- the box must take the mouse: a phantom widget lets clicks through and a drag never starts on it
    widget.floatingWasPhantom = widget:isPhantom()
    widget:setPhantom(false)
    widget.onMousePress = function(self, mousePos, mouseButton)
        return mouseButton == MouseLeftButton or mouseButton == MouseRightButton
    end

    widget.onDragEnter = function(self, mousePos)
        if self.floatingLocked then
            return false
        end
        self.floatingGrab = { x = mousePos.x - self:getX(), y = mousePos.y - self:getY() }
        return true
    end
    widget.onDragMove = function(self, mousePos, mouseMoved)
        if self.floatingGrab then
            place(self, mousePos.x - self.floatingGrab.x, mousePos.y - self.floatingGrab.y)
        end
        return true
    end
    widget.onDragLeave = function(self, droppedWidget, mousePos)
        self.floatingGrab = nil
        saveBox(self)
        return true
    end
    widget.onMouseRelease = function(self, mousePos, mouseButton)
        if mouseButton ~= MouseRightButton or not self:containsPoint(mousePos) then
            return false
        end
        local menu = g_ui.createWidget('PopupMenu')
        menu:setGameMenu(true)
        menu:addCheckBox(tr('Lock position'), self.floatingLocked, function(_, checked)
            FloatingPanel.setLocked(self, checked)
        end)
        if menuBuilder then
            menuBuilder(menu)
        end
        -- opened at the click, kept on the box: containsPoint above already checked this mousePos, the global
        -- g_window.getMousePosition is not tied to the box and opened the menu away from it
        menu:display({
            x = math.max(self:getX(), math.min(mousePos.x, self:getX() + self:getWidth() - 1)),
            y = math.max(self:getY(), math.min(mousePos.y, self:getY() + self:getHeight() - 1))
        })
        return true
    end

    -- a smaller window must not leave the box out of sight
    widget.floatingFit = function()
        if widget:isVisible() and not widget.floatingGrab then
            place(widget, widget:getX(), widget:getY())
        end
    end
    connect(widget:getParent(), { onGeometryChange = widget.floatingFit })
end

function FloatingPanel.detach(widget)
    if widget.floatingFit and widget:getParent() then
        disconnect(widget:getParent(), { onGeometryChange = widget.floatingFit })
    end
    widget.floatingFit = nil
    widget.onDragEnter = nil
    widget.onDragMove = nil
    widget.onDragLeave = nil
    widget.onMousePress = nil
    widget.onMouseRelease = nil
    widget:setDraggable(false)
    if widget.floatingWasPhantom ~= nil then
        widget:setPhantom(widget.floatingWasPhantom)
        widget.floatingWasPhantom = nil
    end
end
