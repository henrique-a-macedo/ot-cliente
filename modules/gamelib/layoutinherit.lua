-- A character with no screen layout of its own (a new one) starts with the layout of the last character played on
-- this computer: side windows (place, size, minimized, closed), skills rows, open chat channels, top menu icons and
-- the extended view columns of inventory/health. Only the neutral client layout: no hotkeys, action bars or bags.
-- gamelib loads before the game modules, so this runs on game start before any of them reads its settings.
local LAST_CHARACTER_KEY = 'LayoutLastCharacter'

-- settings nodes keyed by character name that hold layout
local LAYOUT_NODES = { 'CharMiniWindows', 'skills-hide', 'lastChannelsOpen', 'TopMenuHiddenIcons', 'TopMenuClosedWindows',
    'ExtendedPanelPlaces' }

-- container windows have session ids (container0...) in CharMiniWindows; their layout lives in ContainerLayout
local function isLayoutEntry(node, key)
    return not (node == 'CharMiniWindows' and tostring(key):find('^container'))
end

local function hasLayout(name)
    for _, node in ipairs(LAYOUT_NODES) do
        local all = g_settings.getNode(node)
        if all and all[name] then
            return true
        end
    end
    return false
end

local function copyLayout(from, to)
    for _, node in ipairs(LAYOUT_NODES) do
        local all = g_settings.getNode(node)
        if all and all[from] then
            local copy = {}
            for key, value in pairs(all[from]) do
                if isLayoutEntry(node, key) then
                    copy[key] = value
                end
            end
            all[to] = copy
            g_settings.setNode(node, all)
        end
    end
end

local function onGameStart()
    local name = g_game.getCharacterName()
    if not name or #name == 0 then
        return
    end
    local last = g_settings.getString(LAST_CHARACTER_KEY, '')
    if last ~= '' and last ~= name and not hasLayout(name) and hasLayout(last) then
        copyLayout(last, name)
    end
    g_settings.set(LAST_CHARACTER_KEY, name)
end

connect(g_game, { onGameStart = onGameStart })
