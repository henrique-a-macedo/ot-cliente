-- Quest tracker (server opcode 126, forgottenserver data/scripts/creaturescripts/player/quest_tracker.lua; design in
-- arch .claude/ref/design/quest-tracker.md). The server sends the quests ("list" when asked with "open", "update"
-- when one changes); this module keeps them and which ones are tracked, per character. A view says what to do, never
-- how: a hidden objective comes without its label. Collect objectives are counted here from the backpack so the
-- number moves live; the server checks the real count at the hand-in.
local OPCODE = 126
local TRACKED_NODE = 'QuestTrackerTracked'
-- the server answers the first "open" only after it sent opcode 0 at login
local OPEN_DELAY = 1500

quests = {}       -- id -> view from the server
questOrder = {}   -- ids in the server's order
local changeListeners = {}
local settings = nil -- { tracked = { [id] = true }, autoTrack = bool } of the logged character
local countEvent = nil

local function characterSettings()
    local all = g_settings.getNode(TRACKED_NODE) or {}
    local own = all[g_game.getCharacterName()] or {}
    return { tracked = own.tracked or {}, autoTrack = own.autoTrack ~= false }
end

local function saveSettings()
    local all = g_settings.getNode(TRACKED_NODE) or {}
    all[g_game.getCharacterName()] = settings
    g_settings.setNode(TRACKED_NODE, all)
end

-- callbacks function(id) (id nil: everything changed)
function onChange(callback)
    changeListeners[#changeListeners + 1] = callback
end

local function changed(id)
    for _, callback in ipairs(changeListeners) do
        callback(id)
    end
end

function isTracked(id)
    return settings ~= nil and settings.tracked[id] == true
end

function setTracked(id, on)
    if not settings then
        return
    end
    settings.tracked[id] = on and true or nil
    saveSettings()
    changed(id)
end

function isAutoTrack()
    return settings == nil or settings.autoTrack
end

function setAutoTrack(on)
    if settings then
        settings.autoTrack = on
        saveSettings()
    end
end

function requestList()
    local protocol = g_game.getProtocolGame()
    if protocol then
        protocol:sendExtendedOpcode(OPCODE, 'open')
    end
end

-- items of an id in the inventory and the open containers (client ids, as the server sends them)
local function countItem(itemId)
    local player = g_game.getLocalPlayer()
    local total = 0
    if player then
        for slot = InventorySlotFirst, InventorySlotLast do
            local item = player:getInventoryItem(slot)
            if item and item:getId() == itemId then
                total = total + item:getCount()
            end
        end
    end
    for _, container in pairs(g_game.getContainers()) do
        for _, item in pairs(container:getItems()) do
            if item:getId() == itemId then
                total = total + item:getCount()
            end
        end
    end
    return total
end

-- collect objectives: the live count (capped at the target); others as the server sent them
function objectiveCount(objective)
    if objective.item then
        return math.min(countItem(objective.item), objective.target), objective.target
    end
    return objective.current, objective.target
end

local function hasCollect(view)
    for _, objective in ipairs(view.stage and view.stage.objectives or {}) do
        if objective.item then
            return true
        end
    end
    return false
end

-- the backpack changed: tracked quests with a collect objective redraw (once per burst of changes)
local function recount()
    if countEvent then
        return
    end
    countEvent = scheduleEvent(function()
        countEvent = nil
        for id, view in pairs(quests) do
            if isTracked(id) and hasCollect(view) then
                changed(id)
            end
        end
    end, 200)
end

local function store(view)
    if not quests[view.id] then
        questOrder[#questOrder + 1] = view.id
    end
    quests[view.id] = view
end

local function onMessage(protocol, opcode, data)
    if type(data) ~= 'table' or not settings then
        return
    end
    if data.action == 'list' then
        quests, questOrder = {}, {}
        for _, view in ipairs(data.quests or {}) do
            store(view)
        end
        changed(nil)
    elseif data.action == 'update' and type(data.quest) == 'table' then
        local view = data.quest
        local before = quests[view.id]
        store(view)
        -- a quest that has just started is tracked by default (option "Track new quests")
        if view.state == 'active' and (not before or before.state ~= 'active') and settings.autoTrack then
            settings.tracked[view.id] = true
            saveSettings()
        end
        signalcall(onQuestUpdate, before, view)
        changed(view.id)
    end
end

-- mini window ---------------------------------------------------------------------------------------------------
local miniWindow = nil
local miniButton = nil

-- "Rats 2/3"; a single-step objective shows just its label; a hidden one only its count ("?" for a single step)
local function objectiveText(objective)
    local current, target = objectiveCount(objective)
    local label = objective.hidden and '?' or (objective.label or '?')
    if target <= 1 then
        return label
    end
    return string.format('%s %d/%d', label, current, target)
end

local function drawMini()
    if not miniWindow then
        return
    end
    local list = miniWindow:getChildById('contentsPanel')
    list:destroyChildren()
    local shown = 0
    for _, id in ipairs(questOrder) do
        local view = quests[id]
        if view and view.state == 'active' and isTracked(id) then
            shown = shown + 1
            local title = g_ui.createWidget('QuestMiniTitle', list)
            title:setText(view.name)
            title:setTooltip(view.stage and (view.stage.title .. ': ' .. view.stage.text) or view.name)
            title.onClick = function()
                openJournal(id)
            end
            title.onMouseRelease = function(widget, mousePos, mouseButton)
                if mouseButton ~= MouseRightButton then
                    return false
                end
                local menu = g_ui.createWidget('PopupMenu')
                menu:setGameMenu(true)
                menu:addOption(tr('Stop tracking'), function()
                    setTracked(id, false)
                end)
                menu:addOption(tr('Open in the journal'), function()
                    openJournal(id)
                end)
                menu:display(mousePos)
                return true
            end
            for _, objective in ipairs(view.stage and view.stage.objectives or {}) do
                local line = g_ui.createWidget('QuestMiniObjective', list)
                local current, target = objectiveCount(objective)
                line:setText(objectiveText(objective))
                if current >= target then
                    line:setColor('#7fbf6f')
                end
            end
        end
    end
    if shown == 0 then
        local empty = g_ui.createWidget('QuestMiniEmpty', list)
        empty:setText(tr('No quest tracked. Open the quest journal to track one.'))
    end
end

-- "Quest started / updated / completed" on screen when a tracked quest moves
onQuestUpdate = function(before, after)
    local message
    if after.state == 'done' and before and before.state == 'active' then
        message = tr('Quest completed: %s', after.name)
    elseif after.state == 'active' and (not before or before.state ~= 'active') then
        message = tr('Quest started: %s', after.name)
    elseif after.stage and before and before.stage and after.stage.index ~= before.stage.index then
        message = tr('Quest updated: %s - %s', after.name, after.stage.title)
    end
    if message and modules.game_textmessage then
        modules.game_textmessage.displayGameMessage(message)
    end
end

function onMiniOpen()
    if miniButton then
        miniButton:setOn(true)
    end
    drawMini()
end

function onMiniClose()
    if miniButton then
        miniButton:setOn(false)
    end
end

function toggleMini()
    if not miniWindow then
        return
    end
    if miniWindow:isVisible() then
        miniWindow:close()
        return
    end
    if not miniWindow:getParent() then
        local panel = modules.game_interface.findContentPanelAvailable(miniWindow, miniWindow:getMinimumHeight())
        if not panel then
            return
        end
        panel:addChild(miniWindow)
    end
    miniWindow:open()
end

-- journal ---------------------------------------------------------------------------------------------------------
local journal = nil
local selected = nil

local GROUPS = {
    { title = 'In progress', states = { active = true } },
    { title = 'Available', states = { available = true, locked = true } },
    { title = 'Done', states = { done = true } }
}

local function addText(parent, style, text)
    local label = g_ui.createWidget(style, parent)
    label:setText(text)
    return label
end

local function showDetail(id)
    selected = id
    local detail = journal:getChildById('detail')
    detail:destroyChildren()
    local view = id and quests[id]
    local trackCheck = journal:getChildById('trackCheck')
    trackCheck.updating = true
    trackCheck:setChecked(view ~= nil and isTracked(id))
    trackCheck:setEnabled(view ~= nil and view.state == 'active')
    trackCheck.updating = false
    if not view then
        addText(detail, 'JournalText', tr('Pick a quest on the left.'))
        return
    end
    addText(detail, 'JournalTitle', view.name)
    if view.state == 'locked' then
        addText(detail, 'JournalText', tr('Not available yet: %s', view.reason or '?')):setColor('#c08060')
    elseif view.state == 'done' then
        addText(detail, 'JournalText', tr('Completed.')):setColor('#7fbf6f')
    end
    if view.description ~= '' then
        addText(detail, 'JournalText', view.description)
    end
    if view.start ~= '' and (view.state == 'available' or view.state == 'locked') then
        addText(detail, 'JournalHeading', tr('Where it starts'))
        addText(detail, 'JournalText', view.start)
    end
    if #view.done > 0 then
        addText(detail, 'JournalHeading', tr('Done'))
        addText(detail, 'JournalText', table.concat(view.done, ', '))
    end
    if view.stage then
        addText(detail, 'JournalHeading', tr('Now (%d of %d): %s', view.stage.index, view.stage.count, view.stage.title))
        if view.stage.text ~= '' then
            addText(detail, 'JournalText', view.stage.text)
        end
        for _, objective in ipairs(view.stage.objectives) do
            local current, target = objectiveCount(objective)
            local line = addText(detail, 'JournalText', '- ' .. objectiveText(objective))
            if current >= target then
                line:setColor('#7fbf6f')
            end
        end
        if #view.rewards > 0 then
            addText(detail, 'JournalHeading', tr('Reward for this step'))
            addText(detail, 'JournalText', table.concat(view.rewards, ', '))
        end
    end
    if #view.final > 0 and view.state ~= 'done' then
        addText(detail, 'JournalHeading', tr('Final reward'))
        addText(detail, 'JournalText', table.concat(view.final, ', '))
    end
end

local function drawJournal()
    if not journal or not journal:isVisible() then
        return
    end
    local list = journal:getChildById('questList')
    local filter = journal:getChildById('search'):getText():lower()
    list.onChildFocusChange = nil
    list:destroyChildren()
    local focus = nil
    for _, group in ipairs(GROUPS) do
        local header = nil
        for _, id in ipairs(questOrder) do
            local view = quests[id]
            if view and group.states[view.state] and (filter == '' or view.name:lower():find(filter, 1, true)) then
                if not header then
                    header = addText(list, 'JournalGroup', tr(group.title))
                end
                local row = addText(list, 'JournalQuest', view.name)
                row.questId = id
                if view.state == 'locked' then
                    row:setColor('#808080')
                    row:setTooltip(view.reason)
                end
                if id == selected then
                    focus = row
                end
            end
        end
    end
    if list:getChildCount() == 0 then
        addText(list, 'JournalGroup', tr('No quests yet.'))
    end
    if focus then
        list:focusChild(focus, KeyboardFocusReason)
    end
    list.onChildFocusChange = function(_, child)
        if child and child.questId then
            showDetail(child.questId)
        end
    end
    showDetail(selected)
end

function openJournal(id)
    if not journal then
        return
    end
    if id then
        selected = id
    end
    journal:getChildById('autoTrackCheck'):setChecked(isAutoTrack())
    journal:show()
    journal:raise()
    journal:focus()
    drawJournal()
    requestList()
end

function closeJournal()
    if journal then
        journal:hide()
    end
end

function onTrackCheck(checked)
    local trackCheck = journal and journal:getChildById('trackCheck')
    if trackCheck and not trackCheck.updating and selected then
        setTracked(selected, checked)
    end
end

local function onGameStart()
    settings = characterSettings()
    quests, questOrder = {}, {}
    miniWindow:setupOnStart() -- place, size, minimized and closed per character
    drawMini()
    scheduleEvent(requestList, OPEN_DELAY)
end

local function onGameEnd()
    closeJournal()
    settings = nil
    quests, questOrder = {}, {}
    changed(nil)
end

function init()
    miniWindow = g_ui.loadUI('mini')
    miniWindow:setup()
    miniWindow:setContentMinimumHeight(30)
    for _, id in ipairs({ 'toggleFilterButton', 'newWindowButton' }) do
        local button = miniWindow:recursiveGetChildById(id)
        if button then
            button:setVisible(false)
        end
    end
    miniButton = modules.game_mainpanel.addToggleButton('questTrackerButton', tr('Quest Tracker'),
        '/images/options/button_questlog_tracker', toggleMini, false, 1001)
    journal = g_ui.displayUI('journal')
    journal:hide()
    journal:getChildById('search').onTextChange = function()
        drawJournal()
    end
    -- the mini window's menu button: the journal and the auto-track option
    local menuButton = miniWindow:recursiveGetChildById('contextMenuButton')
    if menuButton then
        menuButton:setVisible(true)
        menuButton.onClick = function(widget, mousePos)
            local menu = g_ui.createWidget('PopupMenu')
            menu:setGameMenu(true)
            menu:addOption(tr('Open quest journal'), function()
                openJournal()
            end)
            menu:addCheckBox(tr('Track new quests'), isAutoTrack(), function(_, checked)
                setAutoTrack(checked)
            end)
            menu:display(mousePos)
            return true
        end
    end
    onChange(function()
        drawMini()
        drawJournal()
    end)
    ProtocolGame.registerExtendedJSONOpcode(OPCODE, onMessage)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    connect(LocalPlayer, { onInventoryChange = recount })
    connect(Container, { onOpen = recount, onClose = recount, onAddItem = recount, onRemoveItem = recount,
        onUpdateItem = recount })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    disconnect(LocalPlayer, { onInventoryChange = recount })
    disconnect(Container, { onOpen = recount, onClose = recount, onAddItem = recount, onRemoveItem = recount,
        onUpdateItem = recount })
    ProtocolGame.unregisterExtendedJSONOpcode(OPCODE)
    if countEvent then
        removeEvent(countEvent)
        countEvent = nil
    end
    if miniButton then
        miniButton:destroy()
        miniButton = nil
    end
    if miniWindow then
        miniWindow:destroy()
        miniWindow = nil
    end
    if journal then
        journal:destroy()
        journal = nil
    end
end
