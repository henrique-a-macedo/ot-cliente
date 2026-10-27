-- Quest tracker (server opcode 126, forgottenserver data/scripts/creaturescripts/player/quest_tracker.lua; design in
-- arch .claude/ref/design/quest-tracker.md). The server sends the quests ("list" when asked with "open", "update"
-- when one changes); this module keeps them and which ones are tracked, per character. A view says what to do, never
-- how: a hidden objective comes without its label. Collect objectives are counted here from the backpack so the
-- number moves live; the server checks the real count at the hand-in. Version 2 (section 12): tags, mystery quests
-- (only what the player already did and the clues found), places on the map (questmap.lua).
OPCODE = 126
local TRACKED_NODE = 'QuestTrackerTracked'
-- the server sends the list at login by itself; "open" after this delay only if it did not arrive (the client may
-- send only after the server's opcode 0)
local OPEN_DELAY = 1500
local listReceived = false

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

-- a line struck through, over the text of a label (done objectives and stages)
function strike(label)
    local line = g_ui.createWidget('JournalStrike', label)
    line:addAnchor(AnchorLeft, 'parent', AnchorLeft)
    line:addAnchor(AnchorVerticalCenter, 'parent', AnchorVerticalCenter)
    line:setMarginLeft(label:getPaddingLeft())
    line:setWidth(label:getTextSize().width)
    return line
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
        listReceived = true
        -- the list comes in parts (the server limits a message to 8 KB): the first starts over, the last redraws
        if data.first ~= false then
            quests, questOrder = {}, {}
        end
        for _, view in ipairs(data.quests or {}) do
            store(view)
        end
        if data.last ~= false then
            changed(nil)
        end
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
        onGuidedQuestChanged(view)
        changed(view.id)
    elseif data.action == 'places' then
        onPlacesMessage(data)
    elseif data.action == 'mapplaces' then
        onMapPlaces(data)
    elseif data.action == 'route' then
        onRouteMessage(data)
    end
end

-- mini window ---------------------------------------------------------------------------------------------------
local miniWindow = nil
local miniButton = nil
local journalButton = nil

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
            -- the name and the GPS button make this the active quest of the GPS (one at a time); again turns it off
            local gpsButton = title:getChildById('gps')
            gpsButton:setVisible(nearestPlaceOf(view) ~= nil)
            gpsButton:setOn(guidedQuest() == id)
            -- the click redraws this window: not inside the event of the widget the redraw destroys
            gpsButton.onClick = function()
                addEvent(function()
                    toggleGuide(id)
                end)
                return true
            end
            title.onClick = function()
                addEvent(function()
                    toggleGuide(id)
                end)
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
                if nearestPlaceOf(view) then
                    menu:addOption(tr('Guide me there'), function()
                        guideTo(id, nearestPlaceOf(view))
                    end)
                end
                if guidedQuest() == id then
                    menu:addOption(tr('Stop guiding'), stopGuide)
                end
                menu:display(mousePos)
                return true
            end
            if view.mystery and view.stage then
                local line = g_ui.createWidget('QuestMiniObjective', list)
                line:setText(view.stage.text)
                line:setColor('#a0a0c0')
            end
            for _, objective in ipairs(view.stage and view.stage.objectives or {}) do
                local line = g_ui.createWidget('QuestMiniObjective', list)
                local current, target = objectiveCount(objective)
                line:setText(objectiveText(objective))
                if current >= target then
                    line:setColor('#7fbf6f')
                    strike(line)
                end
            end
        end
    end
    if shown == 0 then
        local empty = g_ui.createWidget('QuestMiniEmpty', list)
        empty:setText(tr('No quest tracked. Open the quest journal to track one.'))
    end
end

-- the GPS changed its quest: the mini window and the journal list mark the guided one
function refreshMini()
    drawMini()
    if journal and journal:isVisible() then
        drawJournal()
    end
end

-- one active quest for the GPS: this one (the nearest place of its step), or none if it already was
function toggleGuide(id)
    if guidedQuest() == id then
        stopGuide()
        return
    end
    local place = nearestPlaceOf(quests[id])
    if place then
        guideTo(id, place)
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
        message = after.stage.title ~= '' and tr('Quest updated: %s - %s', after.name, after.stage.title) or
            tr('Quest updated: %s', after.name)
    elseif after.state == 'discovered' and not before then
        message = tr('Quest discovered: %s', after.name)
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
-- Search on top (typing filters the list, 1 s after the last key), a tag filter, and one screen with three columns:
-- Quest List | Info | Hints. The list is the player's own quests: the server sends no other (the ones he can take go
-- only as a "!" on the map).
local SEARCH_DEBOUNCE = 1000
local journal = nil
local selected = nil
local searchEvent = nil
local searchText = ''
local tagFilter = nil   -- nil = every tag
local stateFilter = 'active' -- nil = every state; 'active' (in progress, discovered, the default) or 'done'
local openClue = nil  -- index of the clue shown with its source

local TAG_NAMES = { main = 'Main', league = 'Liga', mystery = 'Mystery' }

local GROUPS = {
    { title = 'In progress', states = { active = true, discovered = true } },
    { title = 'Done', states = { done = true } }
}

local function addText(parent, style, text)
    local label = g_ui.createWidget(style, parent)
    label:setText(text)
    return label
end

local function tagText(view)
    local parts = {}
    for _, tag in ipairs(view.tags or {}) do
        parts[#parts + 1] = '[' .. (TAG_NAMES[tag] or tag) .. ']'
    end
    return table.concat(parts, ' ')
end

-- the search looks at the name, the tags and the stage the player is on
local function matches(view)
    if stateFilter == 'done' and view.state ~= 'done' then
        return false
    elseif stateFilter == 'active' and view.state == 'done' then
        return false
    end
    if tagFilter then
        local has = false
        for _, tag in ipairs(view.tags or {}) do
            has = has or tag == tagFilter
        end
        if not has then
            return false
        end
    end
    if searchText == '' then
        return true
    end
    local haystack = (view.name .. ' ' .. tagText(view) .. ' ' .. (view.stage and view.stage.title or '')):lower()
    return haystack:find(searchText, 1, true) ~= nil
end

local function selectedView()
    return selected and quests[selected]
end

local function drawInfo()
    local panel = journal:getChildById('info')
    panel:destroyChildren()
    local view = selectedView()
    if not view then
        addText(panel, 'JournalText', tr('Pick a quest in the list.'))
        return
    end
    addText(panel, 'JournalTitle', view.name)
    local tags = tagText(view)
    if tags ~= '' then
        addText(panel, 'JournalText', tags):setColor('#e8c46a')
    end
    if view.state == 'locked' then
        addText(panel, 'JournalText', tr('Not available yet: %s', view.reason or '?')):setColor('#c08060')
    elseif view.state == 'done' then
        addText(panel, 'JournalText', tr('Completed.')):setColor('#7fbf6f')
    end
    if view.description ~= '' then
        addText(panel, 'JournalText', view.description)
    end
    if view.start ~= '' and (view.state == 'available' or view.state == 'locked') then
        addText(panel, 'JournalHeading', tr('Where it starts'))
        addText(panel, 'JournalText', view.start)
    end
    if #view.done > 0 then
        addText(panel, 'JournalHeading', tr('Done'))
        for _, title in ipairs(view.done) do
            local line = addText(panel, 'JournalObjective', '- ' .. title)
            line:setColor('#7fbf6f')
            strike(line)
        end
    end
    if view.stage then
        if view.mystery then
            addText(panel, 'JournalHeading', tr('Now'))
        else
            addText(panel, 'JournalHeading', tr('Now (%d of %d): %s', view.stage.index, view.stage.count, view.stage.title))
        end
        if view.stage.text ~= '' then
            addText(panel, 'JournalText', view.stage.text)
        end
        for _, objective in ipairs(view.stage.objectives) do
            local current, target = objectiveCount(objective)
            local line = addText(panel, 'JournalObjective', '- ' .. objectiveText(objective))
            if current >= target then
                line:setColor('#7fbf6f')
                strike(line)
            end
        end
    end
    if #view.final > 0 then
        addText(panel, 'JournalHeading', view.state == 'done' and tr('Reward') or tr('Final reward'))
        addText(panel, 'JournalText', table.concat(view.final, ', '))
    end
end

-- a click on a place opens the full map on it (the map shows every place of the tracked quests and of this one)
local function addPlaceLinks(panel, view, objectiveIndex, places, label, more)
    for _, place in ipairs(places) do
        local link = addText(panel, 'JournalLink', placeText(place, label))
        link.onClick = function()
            showPlaces(view.id, place)
        end
    end
end

local function drawHint()
    local panel = journal:getChildById('hint')
    panel:destroyChildren()
    local view = selectedView()
    if not view then
        addText(panel, 'JournalText', tr('Pick a quest in the list.'))
        return
    end
    addText(panel, 'JournalTitle', view.name)
    local any = false
    if not view.mystery then
        if (view.state == 'available' or view.state == 'locked') and view.startPlaces and #view.startPlaces > 0 then
            any = true
            addText(panel, 'JournalHeading', tr('Where it starts'))
            addPlaceLinks(panel, view, nil, view.startPlaces, nil, false)
        end
        for index, objective in ipairs(view.stage and view.stage.objectives or {}) do
            if objective.places and #objective.places > 0 then
                any = true
                addText(panel, 'JournalHeading', objectiveText(objective))
                addPlaceLinks(panel, view, index, objective.places, objective.label, objective.morePlaces)
            end
        end
        if view.stage and view.stage.places and #view.stage.places > 0 then
            any = true
            addText(panel, 'JournalHeading', tr('Places'))
            addPlaceLinks(panel, view, nil, view.stage.places, nil, false)
        end
    end
    if view.clues and #view.clues > 0 then
        any = true
        addText(panel, 'JournalHeading', tr('Clues found'))
        for index, clue in ipairs(view.clues) do
            local link = addText(panel, 'JournalLink', clue.title ~= '' and clue.title or clue.text)
            link.onClick = function()
                openClue = openClue ~= index and index or nil
                drawHint()
            end
            if openClue == index then
                if clue.title ~= '' then
                    addText(panel, 'JournalText', clue.text)
                end
                local source = clue.source or {}
                if source.dialog then
                    addText(panel, 'JournalText', tr('From %s:', source.npc or '?')):setColor('#e8c46a')
                    for _, line in ipairs(source.dialog) do
                        addText(panel, 'JournalText', line):setColor('#a0a0c0')
                    end
                elseif source.text then
                    addText(panel, 'JournalText', source.text):setColor('#a0a0c0')
                end
            end
        end
    end
    if not any then
        addText(panel, 'JournalText', view.mystery and tr('No clues yet. Talk to people, look around.') or
            tr('No place to show for this step: finding it is part of the quest.'))
    end
end

local function drawList()
    local list = journal:getChildById('questList')
    list.onChildFocusChange = nil
    list:destroyChildren()
    local focus = nil
    for _, group in ipairs(GROUPS) do
        local header = nil
        for _, id in ipairs(questOrder) do
            local view = quests[id]
            if view and group.states[view.state] and matches(view) then
                if not header then
                    header = addText(list, 'JournalGroup', tr(group.title))
                end
                local tags = tagText(view)
                local row = g_ui.createWidget('JournalQuest', list)
                row:getChildById('name'):setText(tags ~= '' and (tags .. ' ' .. view.name) or view.name)
                row.questId = id
                -- the GPS of this quest (one active at a time), as in the mini window
                local gpsButton = row:getChildById('gps')
                gpsButton:setVisible(view.state == 'active' and nearestPlaceOf(view) ~= nil)
                gpsButton:setOn(guidedQuest() == id)
                gpsButton.onClick = function()
                    addEvent(function()
                        toggleGuide(id)
                    end)
                end
                -- the check tracks the quest (the mini window); only a quest in progress can be tracked
                local trackCheck = row:getChildById('trackCheck')
                trackCheck:setVisible(view.state == 'active')
                trackCheck:setChecked(isTracked(id))
                trackCheck.onCheckChange = function(_, checked)
                    -- the change redraws the list: not inside the event of this check box
                    addEvent(function()
                        setTracked(id, checked)
                    end)
                end
                -- nothing picked yet: the first quest of the list
                if not selected or not quests[selected] then
                    selected = id
                end
                if id == selected then
                    focus = row
                end
            end
        end
    end
    if list:getChildCount() == 0 then
        addText(list, 'JournalGroup', (searchText ~= '' or stateFilter or tagFilter) and tr('No quest matches.') or tr('No quests yet.'))
    end
    if focus then
        list:focusChild(focus, KeyboardFocusReason)
    end
    -- picking a quest (the list takes the click to move its focus) shows it in Info and Hints; redrawn on the next
    -- frame, not inside the focus event of a row that the redraw destroys
    list.onChildFocusChange = function(_, child)
        if child and child.questId and child.questId ~= selected then
            selected = child.questId
            openClue = nil
            clearPlacesFocus()
            addEvent(drawJournal)
        end
    end
end

-- the three columns at once
function drawJournal()
    if not journal or not journal:isVisible() then
        return
    end
    drawList()
    drawInfo()
    drawHint()
end

local function onSearchChange(widget, text)
    if searchEvent then
        removeEvent(searchEvent)
    end
    searchEvent = scheduleEvent(function()
        searchEvent = nil
        searchText = text:lower()
        drawJournal()
    end, SEARCH_DEBOUNCE)
end

function openJournal(id)
    if not journal then
        return
    end
    journal:getChildById('autoTrackCheck'):setChecked(isAutoTrack())
    journal:show()
    if journalButton then
        journalButton:setOn(true)
    end
    journal:raise()
    journal:focus()
    if id then
        selected = id
        openClue = nil
    end
    drawJournal()
    requestList()
end

function closeJournal()
    if journal then
        journal:hide()
    end
    if journalButton then
        journalButton:setOn(false)
    end
end

-- the "Quest Log" button and key (the Tibia quest log is gone: design/quest-tracker.md, 12.7)
function toggleJournal()
    if journal and journal:isVisible() then
        closeJournal()
    else
        openJournal()
    end
end

local function setupJournal()
    journal = g_ui.displayUI('journal')
    journal:hide()
    journal:getChildById('search').onTextChange = onSearchChange
    local filter = journal:getChildById('tagFilter')
    -- two filters that add up: the state (in progress, completed) and the tag
    filter:addOption(tr('All tags'), '')
    for _, tag in ipairs({ 'main', 'league', 'mystery' }) do
        filter:addOption('[' .. TAG_NAMES[tag] .. ']', tag)
    end
    filter.onOptionChange = function(_, _, data)
        tagFilter = data ~= '' and data or nil
        drawJournal()
    end
    local states = journal:getChildById('stateFilter')
    -- in progress first, and the default (user, 2026-10-26)
    states:addOption(tr('In progress'), 'active')
    states:addOption(tr('Completed'), 'done')
    states:addOption(tr('All quests'), '')
    states.onOptionChange = function(_, _, data)
        stateFilter = data ~= '' and data or nil
        drawJournal()
    end
    journal:getChildById('autoTrackCheck').onCheckChange = function(widget, checked)
        setAutoTrack(checked)
    end
end

local function onGameStart()
    settings = characterSettings()
    quests, questOrder = {}, {}
    miniWindow:setupOnStart() -- place, size, minimized and closed per character
    drawMini()
    listReceived = false
    scheduleEvent(function()
        if not listReceived then
            requestList()
        end
    end, OPEN_DELAY)
end

local function onGameEnd()
    closeJournal()
    clearPlacesFocus()
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
    journalButton = modules.game_mainpanel.addToggleButton('questLogButton', tr('Quest Log'),
        '/images/options/button_questlog', toggleJournal, false, 1000)
    Keybind.new("Windows", "Show/hide quest Log", "", "")
    Keybind.bind("Windows", "Show/hide quest Log", { { type = KEY_DOWN, callback = toggleJournal } })
    setupJournal()
    initPlaces()
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
        scheduleRedrawPlaces()
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
    if searchEvent then
        removeEvent(searchEvent)
        searchEvent = nil
    end
    terminatePlaces()
    if miniButton then
        miniButton:destroy()
        miniButton = nil
    end
    if journalButton then
        journalButton:destroy()
        journalButton = nil
    end
    Keybind.delete("Windows", "Show/hide quest Log")
    if miniWindow then
        miniWindow:destroy()
        miniWindow = nil
    end
    if journal then
        journal:destroy()
        journal = nil
    end
end
