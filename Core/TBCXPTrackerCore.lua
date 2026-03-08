local _, NS = ...
NS = NS or {}

local floor = math.floor
local max = math.max
local format = string.format
local tinsert = table.insert
local sort = table.sort
local sin = math.sin
local cos = math.cos
local rad = math.rad
local deg = math.deg
local abs = math.abs
local pi = math.pi
local atan2 = math.atan2 or function(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + pi
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - pi
    elseif x == 0 and y > 0 then
        return pi / 2
    elseif x == 0 and y < 0 then
        return -pi / 2
    end
    return 0
end
local constants = NS.Constants or {}
local helpers = NS.Helpers or {}
local RATE_HISTORY_SECONDS = constants.RATE_HISTORY_SECONDS or 3600
local MIN_RATE_SAMPLE_SECONDS = constants.MIN_RATE_SAMPLE_SECONDS or 5
local REPORT_CHANNEL_ALIASES = constants.REPORT_CHANNEL_ALIASES or {}
local REPORT_CHANNEL_LABELS = constants.REPORT_CHANNEL_LABELS or {}
local REPORT_CHANNEL_CHOICES = constants.REPORT_CHANNEL_CHOICES or {}

local round = helpers.round or function(n)
    if n >= 0 then
        return floor(n + 0.5)
    end
    return floor(n - 0.5)
end

local trim = helpers.trim or function(text)
    text = text or ""
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local normalizeCommand = helpers.normalizeCommand or function(text)
    return string.lower(trim(text))
end

local splitCommand = helpers.splitCommand or function(text)
    local command, rest = text:match("^(%S+)%s*(.-)$")
    if not command then
        return "", ""
    end
    return command, rest
end

local formatDuration = helpers.formatDuration or function(seconds)
    local total = max(0, floor(seconds))
    local hours = floor(total / 3600)
    local minutes = floor((total % 3600) / 60)
    local secs = total % 60
    return format("%02d:%02d:%02d", hours, minutes, secs)
end

local formatNumber = helpers.formatNumber or function(n)
    local s = tostring(floor(max(0, n)))
    local out = s
    local changed = 0

    while true do
        out, changed = out:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
        if changed == 0 then
            break
        end
    end

    return out
end

local function formatSignedNumber(n)
    local value = floor(tonumber(n) or 0)
    local absolute = value >= 0 and value or -value
    local formatted = formatNumber(absolute)
    if value < 0 then
        return "-" .. formatted
    end
    return formatted
end

local function cloneReputationByFaction(source)
    local copy = {}
    if type(source) ~= "table" then
        return copy
    end

    for factionName, amount in pairs(source) do
        if type(factionName) == "string" and factionName ~= "" then
            local value = floor(tonumber(amount) or 0)
            if value ~= 0 then
                copy[factionName] = value
            end
        end
    end

    return copy
end

local function getReputationTypeTextFromMap(reputationByFaction)
    if type(reputationByFaction) ~= "table" then
        return "-"
    end

    local topFaction
    local topValue = 0
    local nonZeroCount = 0
    for factionName, amount in pairs(reputationByFaction) do
        local value = floor(tonumber(amount) or 0)
        if value ~= 0 then
            nonZeroCount = nonZeroCount + 1
            local currentAbs = abs(value)
            local topAbs = abs(topValue)
            if not topFaction or currentAbs > topAbs or (currentAbs == topAbs and factionName < topFaction) then
                topFaction = factionName
                topValue = value
            end
        end
    end

    if not topFaction then
        return "-"
    end

    local primaryText = topFaction .. ": " .. formatSignedNumber(topValue)
    if nonZeroCount == 1 then
        return primaryText
    end

    return primaryText .. format(" (+%d more)", nonZeroCount - 1)
end

local function countReputationFactions(reputationByFaction)
    if type(reputationByFaction) ~= "table" then
        return 0
    end

    local count = 0
    for _, amount in pairs(reputationByFaction) do
        if floor(tonumber(amount) or 0) ~= 0 then
            count = count + 1
        end
    end
    return count
end

local function getReputationTypeText(instanceRecord)
    if not instanceRecord then
        return "-"
    end
    return getReputationTypeTextFromMap(instanceRecord.reputationByFaction)
end

local state = {
    initialized = false,
    sessionStart = 0,
    totalXP = 0,
    totalReputation = 0,
    lastXP = 0,
    lastXPMax = 0,
    lastLevel = 0,
    lastReputation = {},
    sessionReputationByFaction = {},
    history = {},
    paused = false,
    pauseStartedAt = 0,
    pausedTotal = 0,
    instance = {
        current = nil,
        previous = nil
    },
    historySelectionId = nil
}

local db
local ui = {}
local addonReady = false
local hidePanel
local showPanel
local MINIMAP_BUTTON_RADIUS = 80
local MINIMAP_DRAG_UPDATE_INTERVAL = 0.02

local function canPlayerGainXPNow()
    if type(IsXPUserDisabled) == "function" and IsXPUserDisabled() then
        return false
    end

    local playerLevel = tonumber(UnitLevel("player")) or state.lastLevel or 0
    local maxLevel = 0

    if type(GetMaxPlayerLevel) == "function" then
        maxLevel = tonumber(GetMaxPlayerLevel()) or 0
    end

    if maxLevel <= 0 and type(GetMaximumLevel) == "function" then
        maxLevel = tonumber(GetMaximumLevel()) or 0
    end

    if maxLevel <= 0 and type(MAX_PLAYER_LEVEL) == "number" then
        maxLevel = tonumber(MAX_PLAYER_LEVEL) or 0
    end

    if maxLevel > 0 and playerLevel > 0 and playerLevel >= maxLevel then
        return false
    end

    local xpMax = tonumber(UnitXPMax("player")) or state.lastXPMax or 0
    return xpMax > 0
end

local function isXPEnabledForRecord(record)
    if not record then
        return canPlayerGainXPNow()
    end

    if record == state.instance.current or record.isCurrent then
        return canPlayerGainXPNow()
    end

    if record.xpEnabled ~= nil then
        return record.xpEnabled == true
    end

    return true
end

local function getSessionReputationTypeText()
    return getReputationTypeTextFromMap(state.sessionReputationByFaction)
end

local function getSessionReputationFactionCount()
    return countReputationFactions(state.sessionReputationByFaction)
end

local function normalizeMinimapAngle(angle)
    local normalized = tonumber(angle) or 225
    normalized = normalized % 360
    if normalized < 0 then
        normalized = normalized + 360
    end
    return normalized
end

local function getMinimapButtonAngleFromCursor()
    if not Minimap then
        return 225
    end

    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1
    cx = cx / scale
    cy = cy / scale

    local mx, my = Minimap:GetCenter()
    if not mx or not my then
        return 225
    end

    local angle = deg(atan2(cy - my, cx - mx))
    return normalizeMinimapAngle(angle)
end

local function setMinimapButtonPosition(button, angle)
    if not button or not Minimap then
        return
    end

    local normalizedAngle = normalizeMinimapAngle(angle)
    local angleRadians = rad(normalizedAngle)
    local x = cos(angleRadians) * MINIMAP_BUTTON_RADIUS
    local y = sin(angleRadians) * MINIMAP_BUTTON_RADIUS

    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)

    if db then
        db.minimapAngle = normalizedAngle
    end
end

local function resolveReportChannel(channelText)
    local key = normalizeCommand(channelText)
    if key == "" then
        return nil
    end
    return REPORT_CHANNEL_ALIASES[key]
end

local function getReportChannelLabel(channel)
    return REPORT_CHANNEL_LABELS[channel] or "self"
end

local function getStoredWhisperTarget()
    if not db then
        return ""
    end

    local target = trim(db.reportWhisperTarget or "")
    if target == "" then
        return ""
    end

    return target
end

local function getReportChannelDescription(channel)
    if channel ~= "WHISPER_TARGET" then
        return getReportChannelLabel(channel)
    end

    local target = getStoredWhisperTarget()
    if target == "" then
        return "whisper player (set name)"
    end
    return "whisper player (" .. target .. ")"
end

local function getPartyMemberName(unit)
    if not UnitExists(unit) then
        return nil
    end

    local name, realm = UnitName(unit)
    if not name or name == "" then
        return nil
    end

    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function getPartyWhisperTargets()
    local targets = {}
    for i = 1, 4 do
        local target = getPartyMemberName("party" .. i)
        if target then
            table.insert(targets, target)
        end
    end
    return targets
end

local refreshReportChannelDropdownText
local refreshHistoryReportChannelDropdownText

local function hasPartyWhisperTarget(target)
    if not target or target == "" then
        return false
    end

    local targets = getPartyWhisperTargets()
    for i = 1, #targets do
        if targets[i] == target then
            return true
        end
    end
    return false
end

local function sanitizeWhisperTarget()
    local target = getStoredWhisperTarget()
    if target == "" then
        return
    end

    if hasPartyWhisperTarget(target) then
        return
    end

    if db then
        db.reportWhisperTarget = ""
    end
end

local function refreshWhisperTargetDropdownText()
    local target = getStoredWhisperTarget()
    if ui.whisperTargetDropdown then
        if target == "" then
            UIDropDownMenu_SetText(ui.whisperTargetDropdown, "Select party member")
        else
            UIDropDownMenu_SetText(ui.whisperTargetDropdown, target)
        end
    end

    if refreshReportChannelDropdownText then
        refreshReportChannelDropdownText()
    end
    if refreshHistoryReportChannelDropdownText then
        refreshHistoryReportChannelDropdownText()
    end
end

local function initializeWhisperTargetDropdown()
    if not ui.whisperTargetDropdown then
        return
    end

    UIDropDownMenu_Initialize(ui.whisperTargetDropdown, function(_, level)
        if level ~= 1 then
            return
        end

        local targets = getPartyWhisperTargets()
        if #targets == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "No party members"
            info.disabled = true
            UIDropDownMenu_AddButton(info, level)
            return
        end

        local selected = getStoredWhisperTarget()
        for i = 1, #targets do
            local target = targets[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = target
            info.func = function()
                if db then
                    db.reportWhisperTarget = target
                end
                refreshWhisperTargetDropdownText()
            end
            info.checked = selected == target
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetWidth(ui.whisperTargetDropdown, 132)
    sanitizeWhisperTarget()
    refreshWhisperTargetDropdownText()
end

refreshReportChannelDropdownText = function()
    if not ui.reportChannelDropdown then
        return
    end
    local channel = (db and db.reportChannel) or "SELF"
    UIDropDownMenu_SetText(ui.reportChannelDropdown, getReportChannelDescription(channel))
end

local function refreshWhisperTargetControls()
    if not ui.whisperTargetLabel or not ui.whisperTargetDropdown then
        return
    end

    local isWhisperTarget = db and db.reportChannel == "WHISPER_TARGET"
    if isWhisperTarget then
        ui.whisperTargetLabel:Show()
        ui.whisperTargetDropdown:Show()
    else
        ui.whisperTargetLabel:Hide()
        ui.whisperTargetDropdown:Hide()
    end
end

local function setReportChannel(channel)
    if not REPORT_CHANNEL_LABELS[channel] then
        channel = "SELF"
    end

    if db then
        db.reportChannel = channel
    end
    refreshReportChannelDropdownText()
    refreshWhisperTargetControls()
end

local function initializeReportChannelDropdown()
    if not ui.reportChannelDropdown then
        return
    end

    UIDropDownMenu_Initialize(ui.reportChannelDropdown, function(_, level)
        if level ~= 1 then
            return
        end

        for i = 1, #REPORT_CHANNEL_CHOICES do
            local option = REPORT_CHANNEL_CHOICES[i]
            local info = UIDropDownMenu_CreateInfo()
            if option.value == "WHISPER_TARGET" then
                info.text = getReportChannelDescription("WHISPER_TARGET")
            else
                info.text = option.text
            end
            info.func = function()
                setReportChannel(option.value)
            end
            info.checked = db and db.reportChannel == option.value
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetWidth(ui.reportChannelDropdown, 132)
    refreshReportChannelDropdownText()
    refreshWhisperTargetControls()
end

refreshHistoryReportChannelDropdownText = function()
    if not ui.historyReportChannelDropdown then
        return
    end
    local channel = (db and db.historyReportChannel) or "SELF"
    UIDropDownMenu_SetText(ui.historyReportChannelDropdown, getReportChannelDescription(channel))
end

local function setHistoryReportChannel(channel)
    if not REPORT_CHANNEL_LABELS[channel] then
        channel = "SELF"
    end

    if db then
        db.historyReportChannel = channel
    end
    refreshHistoryReportChannelDropdownText()
end

local function initializeHistoryReportChannelDropdown()
    if not ui.historyReportChannelDropdown then
        return
    end

    UIDropDownMenu_Initialize(ui.historyReportChannelDropdown, function(_, level)
        if level ~= 1 then
            return
        end

        for i = 1, #REPORT_CHANNEL_CHOICES do
            local option = REPORT_CHANNEL_CHOICES[i]
            local info = UIDropDownMenu_CreateInfo()
            if option.value == "WHISPER_TARGET" then
                info.text = getReportChannelDescription("WHISPER_TARGET")
            else
                info.text = option.text
            end
            info.func = function()
                setHistoryReportChannel(option.value)
            end
            info.checked = db and db.historyReportChannel == option.value
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_SetWidth(ui.historyReportChannelDropdown, 132)
    refreshHistoryReportChannelDropdownText()
end

local function getActiveTime()
    local now = time()
    local pausedFor = 0
    if state.paused then
        pausedFor = now - state.pauseStartedAt
    end
    return now - state.pausedTotal - pausedFor
end

local function getXPPerHour(totalXP, startTime, endTime)
    local span = max(MIN_RATE_SAMPLE_SECONDS, (endTime or 0) - (startTime or 0))
    return floor((max(0, totalXP) / span) * 3600 + 0.5)
end

local function getFactionReputationSnapshot()
    if type(GetNumFactions) ~= "function" or type(GetFactionInfo) ~= "function" then
        return {}
    end

    local snapshot = {}
    local expandedHeaders = {}
    local canExpandHeaders = type(ExpandFactionHeader) == "function" and type(CollapseFactionHeader) == "function"
    local i = 1
    while i <= (tonumber(GetNumFactions()) or 0) do
        local name, _, _, _, _, barValue, _, _, isHeader, isCollapsed, hasRep = GetFactionInfo(i)
        if canExpandHeaders and name and isHeader and isCollapsed then
            tinsert(expandedHeaders, i)
            ExpandFactionHeader(i)
        elseif name and not isHeader and (hasRep == nil or hasRep) then
            local key = tostring(name)
            snapshot[key] = tonumber(barValue) or 0
        end
        i = i + 1
    end

    for j = #expandedHeaders, 1, -1 do
        CollapseFactionHeader(expandedHeaders[j])
    end

    return snapshot
end

local function isTrackableInstanceType(instanceType)
    return instanceType == "party" or instanceType == "raid"
end

local function getInstanceContext()
    local inInstance, instanceType = IsInInstance()
    if not inInstance or not isTrackableInstanceType(instanceType) then
        return nil
    end

    local name = GetRealZoneText()
    if not name or name == "" then
        local instanceName = GetInstanceInfo()
        name = instanceName or "Unknown Instance"
    end

    local key = instanceType .. ":" .. name
    return {
        key = key,
        name = name,
        type = instanceType
    }
end

local allocateHistoryId
local addHistoryRecord
local persistInstanceData

local function finishCurrentInstance()
    local current = state.instance.current
    if not current then
        return
    end

    current.endTime = getActiveTime()
    current.endedAt = time()
    if isTrackableInstanceType(current.type) then
        state.instance.previous = current
        addHistoryRecord(current)
    end
    state.instance.current = nil
    persistInstanceData()
end

local function startInstance(context)
    state.instance.current = {
        id = allocateHistoryId(),
        key = context.key,
        name = context.name,
        type = context.type,
        startTime = getActiveTime(),
        endTime = nil,
        totalXP = 0,
        totalReputation = 0,
        reputationByFaction = {},
        xpEnabled = canPlayerGainXPNow(),
        startedAt = time(),
        endedAt = nil
    }
    persistInstanceData()
end

local function refreshInstanceContext()
    local context = getInstanceContext()
    local current = state.instance.current

    if not context then
        if current then
            finishCurrentInstance()
        end
        return
    end

    if not current then
        startInstance(context)
        return
    end

    if current.key ~= context.key then
        finishCurrentInstance()
        startInstance(context)
        return
    end

    local xpEnabledNow = canPlayerGainXPNow()
    if current.xpEnabled ~= xpEnabledNow then
        current.xpEnabled = xpEnabledNow
        persistInstanceData()
    end
end

local function getInstanceStats(instanceRecord)
    if not instanceRecord then
        return nil
    end

    local endTime = instanceRecord.endTime or getActiveTime()
    local duration = max(0, endTime - instanceRecord.startTime)
    local rate = getXPPerHour(instanceRecord.totalXP, instanceRecord.startTime, endTime)
    return {
        name = instanceRecord.name,
        totalXP = instanceRecord.totalXP,
        totalReputation = tonumber(instanceRecord.totalReputation) or 0,
        duration = duration,
        rate = rate
    }
end

local function cloneInstanceRecord(record)
    if type(record) ~= "table" then
        return nil
    end

    local name = record.name
    if type(name) ~= "string" or name == "" then
        return nil
    end

    local startTime = tonumber(record.startTime) or time()
    local endTime = tonumber(record.endTime)
    local totalXP = max(0, floor(tonumber(record.totalXP) or 0))
    local totalReputation = floor(tonumber(record.totalReputation) or 0)
    local id = tonumber(record.id)
    local startedAt = tonumber(record.startedAt)
    local endedAt = tonumber(record.endedAt)
    local xpEnabled = record.xpEnabled
    if xpEnabled ~= nil then
        xpEnabled = xpEnabled == true
    end

    return {
        id = id and floor(id) or nil,
        key = tostring(record.key or ""),
        name = name,
        type = tostring(record.type or ""),
        startTime = startTime,
        endTime = endTime,
        totalXP = totalXP,
        totalReputation = totalReputation,
        reputationByFaction = cloneReputationByFaction(record.reputationByFaction),
        xpEnabled = xpEnabled,
        startedAt = startedAt,
        endedAt = endedAt
    }
end

local function isSameInstanceRun(a, b)
    if not a or not b then
        return false
    end

    if a.id and b.id then
        return a.id == b.id
    end

    return a.key == b.key and a.startTime == b.startTime
end

local function ensureHistoryStorage()
    if not db then
        return
    end

    if type(db.instanceHistory) ~= "table" then
        db.instanceHistory = {}
    end

    db.instanceHistoryNextId = max(1, floor(tonumber(db.instanceHistoryNextId) or 1))
end

allocateHistoryId = function()
    ensureHistoryStorage()
    local id = db and db.instanceHistoryNextId or 1
    if db then
        db.instanceHistoryNextId = id + 1
    end
    return id
end

addHistoryRecord = function(record)
    if not db then
        return
    end

    local copy = cloneInstanceRecord(record)
    if not copy or not copy.endTime then
        return
    end
    if not isTrackableInstanceType(copy.type) then
        return
    end

    ensureHistoryStorage()

    if not copy.id or copy.id <= 0 then
        copy.id = allocateHistoryId()
    end

    for i = 1, #db.instanceHistory do
        local existing = db.instanceHistory[i]
        if type(existing) == "table" and tonumber(existing.id) == copy.id then
            return
        end
    end

    tinsert(db.instanceHistory, 1, copy)
end

persistInstanceData = function()
    if not db then
        return
    end

    ensureHistoryStorage()

    db.instanceData = {
        current = cloneInstanceRecord(state.instance.current),
        previous = cloneInstanceRecord(state.instance.previous)
    }
end

local function restoreInstanceData()
    if not db then
        return
    end

    ensureHistoryStorage()

    if type(db.instanceData) ~= "table" then
        return
    end

    state.instance.current = cloneInstanceRecord(db.instanceData.current)
    state.instance.previous = cloneInstanceRecord(db.instanceData.previous)
    if state.instance.current and not isTrackableInstanceType(state.instance.current.type) then
        state.instance.current = nil
    end
    if state.instance.previous and not isTrackableInstanceType(state.instance.previous.type) then
        state.instance.previous = nil
    end
    if isSameInstanceRun(state.instance.current, state.instance.previous) then
        state.instance.previous = nil
    end
end

local function migrateLegacyInstanceHistory()
    if not db then
        return
    end

    ensureHistoryStorage()

    if state.instance.current then
        if not isTrackableInstanceType(state.instance.current.type) then
            state.instance.current = nil
        end
    end

    if state.instance.previous then
        if not isTrackableInstanceType(state.instance.previous.type) then
            state.instance.previous = nil
        end
    end
    if isSameInstanceRun(state.instance.current, state.instance.previous) then
        state.instance.previous = nil
    end

    if state.instance.current then
        if not state.instance.current.id or state.instance.current.id <= 0 then
            state.instance.current.id = allocateHistoryId()
        end
        if state.instance.current.xpEnabled == nil then
            state.instance.current.xpEnabled = canPlayerGainXPNow()
        end
        if not state.instance.current.startedAt then
            state.instance.current.startedAt = time()
        end
    end

    if state.instance.previous then
        if not state.instance.previous.id or state.instance.previous.id <= 0 then
            state.instance.previous.id = allocateHistoryId()
        end
        if state.instance.previous.endTime and not state.instance.previous.endedAt then
            state.instance.previous.endedAt = time()
        end
    end

    if #db.instanceHistory == 0 and state.instance.previous and state.instance.previous.endTime then
        addHistoryRecord(state.instance.previous)
    end

    persistInstanceData()
end

local function pruneHistory(now)
    while #state.history > 0 and (now - state.history[1].t) > RATE_HISTORY_SECONDS do
        table.remove(state.history, 1)
    end
end

local function addGain(amount)
    if amount <= 0 then
        return
    end

    local now = getActiveTime()
    state.totalXP = state.totalXP + amount
    table.insert(state.history, { t = now, xp = amount })
    pruneHistory(now)
end

local function getRollingRate()
    local now = getActiveTime()
    pruneHistory(now)

    if #state.history == 0 then
        return 0
    end

    local windowStart = state.history[1].t
    local windowSpan = max(1, now - windowStart)
    local sessionSpan = max(1, now - state.sessionStart)
    local effectiveSpan = max(MIN_RATE_SAMPLE_SECONDS, windowSpan, sessionSpan)
    local xp = 0

    for i = 1, #state.history do
        xp = xp + state.history[i].xp
    end

    return floor((xp / effectiveSpan) * 3600 + 0.5)
end

local function buildSessionReportData()
    local elapsed = max(0, getActiveTime() - state.sessionStart)
    if not canPlayerGainXPNow() then
        return {
            title = "session",
            lines = {
                format("Rep gained: %s", formatSignedNumber(state.totalReputation)),
                format("Rep type: %s", getSessionReputationTypeText()),
                format("Session: %s", formatDuration(elapsed))
            }
        }
    end

    return {
        title = "session",
        lines = {
            format("XP gained: %s", formatNumber(state.totalXP)),
            format("XP/hour: %s", formatNumber(getRollingRate())),
            format("Session: %s", formatDuration(elapsed))
        }
    }
end

local function buildInstanceReportData(instanceRecord)
    local stats = getInstanceStats(instanceRecord)
    if not stats then
        return nil
    end

    if not isXPEnabledForRecord(instanceRecord) then
        return {
            title = format("instance %s", stats.name),
            lines = {
                format("Rep gained: %s", formatSignedNumber(stats.totalReputation)),
                format("Rep type: %s", getReputationTypeText(instanceRecord)),
                format("Session: %s", formatDuration(stats.duration))
            }
        }
    end

    return {
        title = format("instance %s", stats.name),
        lines = {
            format("XP gained: %s", formatNumber(stats.totalXP)),
            format("XP/hour: %s", formatNumber(stats.rate)),
            format("Session: %s", formatDuration(stats.duration))
        }
    }
end

local function buildReportData(reportRecord)
    if reportRecord then
        return buildInstanceReportData(reportRecord)
    end

    local currentStats = buildInstanceReportData(state.instance.current)
    if currentStats then
        return currentStats
    end

    return buildSessionReportData()
end

local function sendReport(targetChannel, reportRecord)
    local channel = targetChannel or (db and db.reportChannel) or "SELF"
    local reportData = buildReportData(reportRecord)
    if not reportData then
        return false
    end
    local reportMessage = "TBC XP Tracker: " .. reportData.title .. " - " .. table.concat(reportData.lines, " - ")

    if channel == "SELF" then
        print(reportMessage)
        return true
    end

    if channel == "WHISPER_TARGET" then
        local target = getStoredWhisperTarget()
        if target == "" then
            return false
        end

        if not hasPartyWhisperTarget(target) then
            return false
        end

        local whisperMessage = reportMessage:gsub("XP", "xp")
        SendChatMessage(whisperMessage, "WHISPER", nil, target)
        return true
    end

    SendChatMessage(reportMessage, channel)
    return true
end

local refreshHistoryModal

local function isHistoryDropdownOpen()
    local openMenu = UIDROPDOWNMENU_OPEN_MENU
    if not openMenu then
        return false
    end

    if ui.historyDropdown and openMenu == ui.historyDropdown then
        return true
    end
    if ui.historyReportChannelDropdown and openMenu == ui.historyReportChannelDropdown then
        return true
    end

    return false
end

local function formatHistoryTimestamp(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then
        return "unknown"
    end
    return date("%Y-%m-%d %H:%M", ts)
end

local function getHistoryRecordSortTime(record)
    if not record then
        return 0
    end
    return tonumber(record.endedAt) or tonumber(record.startedAt) or tonumber(record.endTime) or tonumber(record.startTime) or 0
end

local function getHistoryEntryLabel(record)
    if not record then
        return "unknown run"
    end

    local stamp = formatHistoryTimestamp(record.endedAt or record.startedAt)
    if not isXPEnabledForRecord(record) then
        local repText = formatSignedNumber(record.totalReputation or 0)
        if record.isCurrent then
            return stamp .. " - " .. repText .. " rep (current)"
        end
        return stamp .. " - " .. repText .. " rep"
    end

    local xpText = formatNumber(record.totalXP or 0)
    if record.isCurrent then
        return stamp .. " - " .. xpText .. " xp (current)"
    end
    return stamp .. " - " .. xpText .. " xp"
end

local function buildHistoryGroups()
    local entries = {}
    if db and type(db.instanceHistory) == "table" then
        for i = 1, #db.instanceHistory do
            local copy = cloneInstanceRecord(db.instanceHistory[i])
            if copy and copy.endTime and isTrackableInstanceType(copy.type) then
                tinsert(entries, copy)
            end
        end
    end

    local currentCopy = cloneInstanceRecord(state.instance.current)
    if currentCopy then
        currentCopy.isCurrent = true
        if not currentCopy.id or currentCopy.id <= 0 then
            currentCopy.id = -1
        end
        tinsert(entries, 1, currentCopy)
    end

    sort(entries, function(a, b)
        return getHistoryRecordSortTime(a) > getHistoryRecordSortTime(b)
    end)

    local groupsByName = {}
    local groups = {}
    for i = 1, #entries do
        local entry = entries[i]
        local groupName = entry.name or "Unknown Instance"
        if not groupsByName[groupName] then
            groupsByName[groupName] = {
                name = groupName,
                entries = {}
            }
            tinsert(groups, groupsByName[groupName])
        end
        tinsert(groupsByName[groupName].entries, entry)
    end

    sort(groups, function(a, b)
        local aTime = getHistoryRecordSortTime(a.entries[1])
        local bTime = getHistoryRecordSortTime(b.entries[1])
        if aTime == bTime then
            return a.name < b.name
        end
        return aTime > bTime
    end)

    return groups
end

local function pickSelectedHistoryRecord(groups)
    local firstRecord
    local selected
    for i = 1, #groups do
        local group = groups[i]
        for j = 1, #group.entries do
            local entry = group.entries[j]
            if not firstRecord then
                firstRecord = entry
            end
            if state.historySelectionId and entry.id == state.historySelectionId then
                selected = entry
            end
        end
    end

    if selected then
        return selected
    end

    state.historySelectionId = firstRecord and firstRecord.id or nil
    return firstRecord
end

local function layoutHistoryDetailsRows(showXP)
    if not ui.historyDetailsRows or not ui.historyDetailsState then
        return
    end

    local rows = ui.historyDetailsRows
    local visibleRows = {
        rows.type,
        rows.start,
        rows["end"],
        rows.rep,
        rows.repType,
        rows.duration
    }
    if showXP then
        table.insert(visibleRows, 4, rows.xp)
        table.insert(visibleRows, 7, rows.rate)
    end

    for _, row in pairs(rows) do
        row.label:Hide()
        row.value:Hide()
    end

    local anchorWidget = ui.historyDetailsState
    for i = 1, #visibleRows do
        local row = visibleRows[i]
        row.label:ClearAllPoints()
        row.label:SetPoint("TOPLEFT", anchorWidget, "BOTTOMLEFT", 0, -8)
        row.value:ClearAllPoints()
        row.value:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
        row.label:Show()
        row.value:Show()
        anchorWidget = row.label
    end
end

local function refreshHistoryDetails(record)
    if not ui.historyDetailsTitle then
        return
    end

    local showXP = isXPEnabledForRecord(record)
    layoutHistoryDetailsRows(showXP)

    if not record then
        ui.historyDetailsTitle:SetText("No instance history yet")
        if ui.historyDetailsState then
            ui.historyDetailsState:SetText("Run State: -")
        end
        ui.historyDetailsType:SetText("-")
        ui.historyDetailsStart:SetText("-")
        ui.historyDetailsEnd:SetText("-")
        ui.historyDetailsXP:SetText("0")
        if ui.historyDetailsRep then
            ui.historyDetailsRep:SetText("0")
        end
        if ui.historyDetailsRepType then
            ui.historyDetailsRepType:SetText("-")
        end
        ui.historyDetailsRate:SetText("0")
        ui.historyDetailsTime:SetText("00:00:00")
        return
    end

    local stats = getInstanceStats(record) or { totalXP = 0, totalReputation = 0, rate = 0, duration = 0 }
    local runState = record.isCurrent and "Current run" or "Finished run"
    local typeText = record.type or ""
    if typeText == "" then
        typeText = "unknown"
    end

    ui.historyDetailsTitle:SetText(record.name)
    if ui.historyDetailsState then
        ui.historyDetailsState:SetText("Run State: " .. runState)
    end
    ui.historyDetailsType:SetText(typeText)
    ui.historyDetailsStart:SetText(formatHistoryTimestamp(record.startedAt))
    if record.isCurrent then
        ui.historyDetailsEnd:SetText("in progress")
    else
        ui.historyDetailsEnd:SetText(formatHistoryTimestamp(record.endedAt))
    end
    ui.historyDetailsXP:SetText(formatNumber(stats.totalXP))
    if ui.historyDetailsRep then
        ui.historyDetailsRep:SetText(formatSignedNumber(stats.totalReputation))
    end
    if ui.historyDetailsRepType then
        ui.historyDetailsRepType:SetText(getReputationTypeText(record))
    end
    if showXP then
        ui.historyDetailsRate:SetText(formatNumber(stats.rate))
    else
        ui.historyDetailsRate:SetText("0")
    end
    ui.historyDetailsTime:SetText(formatDuration(stats.duration))
end

local function createHistoryModal()
    local historyFrame = CreateFrame("Frame", "TBCXPTrackerHistoryFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    historyFrame:SetSize(480, 360)
    historyFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    historyFrame:SetFrameStrata("DIALOG")
    historyFrame:SetClampedToScreen(true)
    historyFrame:EnableMouse(true)
    historyFrame:SetMovable(true)
    historyFrame:RegisterForDrag("LeftButton")
    historyFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    historyFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)

    if historyFrame.SetBackdrop then
        historyFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        historyFrame:SetBackdropColor(0.02, 0.03, 0.04, 0.95)
    end

    local header = historyFrame:CreateTexture(nil, "ARTWORK")
    header:SetColorTexture(0.08, 0.11, 0.16, 0.9)
    header:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 5, -5)
    header:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -5, -5)
    header:SetHeight(28)

    local headerBottom = historyFrame:CreateTexture(nil, "ARTWORK")
    headerBottom:SetColorTexture(1, 1, 1, 0.1)
    headerBottom:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    headerBottom:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    headerBottom:SetHeight(1)

    local title = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", header, "LEFT", 10, 0)
    title:SetText("Instance History")
    title:SetTextColor(1, 0.82, 0.1)

    local closeButton = CreateFrame("Button", nil, historyFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -4, -4)

    local selectionLabel = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selectionLabel:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 12, -44)
    selectionLabel:SetText("Run selector")
    selectionLabel:SetTextColor(0.65, 0.72, 0.86)
    selectionLabel:SetJustifyH("LEFT")

    local historyDropdown = CreateFrame("Frame", "TBCXPTrackerHistoryDropdown", historyFrame, "UIDropDownMenuTemplate")
    historyDropdown:SetPoint("TOPLEFT", selectionLabel, "BOTTOMLEFT", -12, -2)

    local historyReportChannelLabel = historyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    historyReportChannelLabel:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 12, -82)
    historyReportChannelLabel:SetText("Report channel")
    historyReportChannelLabel:SetTextColor(0.65, 0.72, 0.86)
    historyReportChannelLabel:SetJustifyH("LEFT")

    local historyReportChannelDropdown = CreateFrame("Frame", "TBCXPTrackerHistoryReportChannelDropdown", historyFrame, "UIDropDownMenuTemplate")
    historyReportChannelDropdown:SetPoint("TOPLEFT", historyReportChannelLabel, "BOTTOMLEFT", -10, -2)

    local divider = historyFrame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 10, -138)
    divider:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -10, -138)
    divider:SetHeight(1)

    local detailsPanel = CreateFrame("Frame", nil, historyFrame, BackdropTemplateMixin and "BackdropTemplate")
    detailsPanel:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 12, -148)
    detailsPanel:SetPoint("BOTTOMRIGHT", historyFrame, "BOTTOMRIGHT", -12, 12)
    if detailsPanel.SetBackdrop then
        detailsPanel:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        detailsPanel:SetBackdropColor(0.04, 0.07, 0.1, 0.85)
    end

    local detailsPanelHeader = detailsPanel:CreateTexture(nil, "ARTWORK")
    detailsPanelHeader:SetColorTexture(0.1, 0.14, 0.2, 0.85)
    detailsPanelHeader:SetPoint("TOPLEFT", detailsPanel, "TOPLEFT", 3, -3)
    detailsPanelHeader:SetPoint("TOPRIGHT", detailsPanel, "TOPRIGHT", -3, -3)
    detailsPanelHeader:SetHeight(22)

    local detailsTitle = detailsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailsTitle:SetPoint("LEFT", detailsPanelHeader, "LEFT", 8, 0)
    detailsTitle:SetJustifyH("LEFT")

    local detailsState = detailsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailsState:SetPoint("TOPLEFT", detailsPanelHeader, "BOTTOMLEFT", 8, -10)
    detailsState:SetJustifyH("LEFT")
    detailsState:SetTextColor(0.82, 0.88, 1)

    local function createDetailsRow(anchorWidget, titleText)
        local label = detailsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if anchorWidget then
            label:SetPoint("TOPLEFT", anchorWidget, "BOTTOMLEFT", 0, -8)
        else
            label:SetPoint("TOPLEFT", detailsPanel, "TOPLEFT", 8, -48)
        end
        label:SetText(titleText)
        label:SetTextColor(0.65, 0.72, 0.86)

        local value = detailsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        value:SetPoint("LEFT", label, "RIGHT", 8, 0)
        value:SetJustifyH("LEFT")
        value:SetWidth(300)
        return label, value
    end

    local typeLabel, detailsType = createDetailsRow(detailsState, "Type:")
    local startLabel, detailsStart = createDetailsRow(typeLabel, "Start:")
    local endLabel, detailsEnd = createDetailsRow(startLabel, "End:")
    local xpLabel, detailsXP = createDetailsRow(endLabel, "XP gained:")
    local repLabel, detailsRep = createDetailsRow(xpLabel, "Rep gained:")
    local repTypeLabel, detailsRepType = createDetailsRow(repLabel, "Rep type:")
    local rateLabel, detailsRate = createDetailsRow(repTypeLabel, "XP/hour:")
    local timeLabel, detailsTime = createDetailsRow(rateLabel, "Duration:")

    local refreshButton = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
    refreshButton:SetSize(80, 20)
    refreshButton:SetPoint("TOPRIGHT", historyFrame, "TOPRIGHT", -28, -70)
    refreshButton:SetText("Refresh")
    refreshButton:SetScript("OnClick", function()
        if refreshHistoryModal then
            refreshHistoryModal()
        end
    end)

    local reportButton = CreateFrame("Button", nil, historyFrame, "UIPanelButtonTemplate")
    reportButton:SetSize(80, 20)
    reportButton:SetPoint("RIGHT", refreshButton, "LEFT", -8, 0)
    reportButton:SetText("Send")
    reportButton:SetScript("OnClick", function()
        sendReport((db and db.historyReportChannel) or "SELF", ui.historySelectedRecord)
    end)

    historyFrame:Hide()

    ui.historyFrame = historyFrame
    ui.historyDropdown = historyDropdown
    ui.historyDetailsTitle = detailsTitle
    ui.historyDetailsState = detailsState
    ui.historyDetailsType = detailsType
    ui.historyDetailsStart = detailsStart
    ui.historyDetailsEnd = detailsEnd
    ui.historyDetailsXP = detailsXP
    ui.historyDetailsRep = detailsRep
    ui.historyDetailsRepType = detailsRepType
    ui.historyDetailsRate = detailsRate
    ui.historyDetailsTime = detailsTime
    ui.historyDetailsRows = {
        type = { label = typeLabel, value = detailsType },
        start = { label = startLabel, value = detailsStart },
        ["end"] = { label = endLabel, value = detailsEnd },
        xp = { label = xpLabel, value = detailsXP },
        rep = { label = repLabel, value = detailsRep },
        repType = { label = repTypeLabel, value = detailsRepType },
        rate = { label = rateLabel, value = detailsRate },
        duration = { label = timeLabel, value = detailsTime }
    }
    ui.historyReportButton = reportButton
    ui.historyReportChannelLabel = historyReportChannelLabel
    ui.historyReportChannelDropdown = historyReportChannelDropdown

    initializeHistoryReportChannelDropdown()
end

refreshHistoryModal = function()
    if not ui.historyFrame then
        return
    end

    local groups = buildHistoryGroups()
    local selectedRecord = pickSelectedHistoryRecord(groups)

    if ui.historyDropdown then
        UIDropDownMenu_Initialize(ui.historyDropdown, function(_, level, menuList)
            if level == 1 then
                if #groups == 0 then
                    local emptyInfo = UIDropDownMenu_CreateInfo()
                    emptyInfo.text = "No history yet"
                    emptyInfo.disabled = true
                    UIDropDownMenu_AddButton(emptyInfo, level)
                    return
                end

                for i = 1, #groups do
                    local group = groups[i]
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = format("%s (%d)", group.name, #group.entries)
                    info.hasArrow = true
                    info.notCheckable = true
                    info.menuList = i
                    UIDropDownMenu_AddButton(info, level)
                end
            elseif level == 2 then
                local group = groups[menuList]
                if not group then
                    return
                end

                for i = 1, #group.entries do
                    local entry = group.entries[i]
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = getHistoryEntryLabel(entry)
                    info.checked = selectedRecord and selectedRecord.id == entry.id
                    info.func = function()
                        state.historySelectionId = entry.id
                        refreshHistoryModal()
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end)
        local dropdownWidth = 330
        if ui.historyReportButton then
            local dropdownLeft = ui.historyDropdown:GetLeft()
            local reportLeft = ui.historyReportButton:GetLeft()
            if dropdownLeft and reportLeft and reportLeft > dropdownLeft then
                -- Keep a small horizontal gap and account for dropdown chrome around the text field.
                dropdownWidth = max(180, floor(reportLeft - dropdownLeft - 34))
            end
        end

        UIDropDownMenu_SetWidth(ui.historyDropdown, dropdownWidth)
        if selectedRecord then
            UIDropDownMenu_SetText(ui.historyDropdown, selectedRecord.name .. " (" .. formatHistoryTimestamp(selectedRecord.endedAt or selectedRecord.startedAt) .. ")")
        else
            UIDropDownMenu_SetText(ui.historyDropdown, "No instance history")
        end
    end

    ui.historySelectedRecord = selectedRecord
    if ui.historyReportButton then
        ui.historyReportButton:SetEnabled(selectedRecord ~= nil)
    end

    refreshHistoryReportChannelDropdownText()
    refreshHistoryDetails(selectedRecord)
end

local function openHistoryModal()
    if not ui.historyFrame then
        createHistoryModal()
    end

    ui.historyFrame:Show()
    ui.historyFrame:Raise()
    refreshHistoryModal()
end

local function toggleHistoryModal()
    if not ui.historyFrame then
        createHistoryModal()
    end

    if ui.historyFrame:IsShown() then
        ui.historyFrame:Hide()
    else
        openHistoryModal()
    end
end

local function createMinimapButton()
    if ui.minimapButton then
        return true
    end

    if not Minimap then
        return false, "minimap not ready"
    end

    local button = CreateFrame("Button", "TBCXPTrackerMinimapButton", Minimap)
    button:SetSize(33, 33)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetClampedToScreen(false)

    setMinimapButtonPosition(button, db and db.minimapAngle or 225)

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("TOPLEFT")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
    icon:SetSize(21, 21)
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)

    button:SetScript("OnDragStart", function(self)
        self.dragElapsed = 0
        self:SetScript("OnUpdate", function(frame, elapsed)
            frame.dragElapsed = frame.dragElapsed + elapsed
            if frame.dragElapsed < MINIMAP_DRAG_UPDATE_INTERVAL then
                return
            end
            frame.dragElapsed = 0
            setMinimapButtonPosition(frame, getMinimapButtonAngleFromCursor())
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        setMinimapButtonPosition(self, getMinimapButtonAngleFromCursor())
        self.lastDragStop = GetTime()
    end)

    button:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" and self.lastDragStop and (GetTime() - self.lastDragStop) < 0.2 then
            return
        end

        if mouseButton == "RightButton" then
            if ui.frame and ui.frame:IsShown() then
                hidePanel()
            else
                showPanel(false)
            end
            return
        end
        toggleHistoryModal()
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("TBC XP Tracker")
        GameTooltip:AddLine("Left-click: open instance history", 1, 1, 1)
        GameTooltip:AddLine("Right-click: show/hide tracker", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    ui.minimapButton = button
    return true
end

local function ensureMinimapButton(attempt)
    if ui.minimapButton then
        return
    end

    local try = tonumber(attempt) or 1
    local ok, created, reason = pcall(createMinimapButton)
    if ok and created then
        return
    end

    if try >= 10 then
        local err = ok and tostring(reason or "unknown reason") or tostring(created or "unknown error")
        print(format("|cff33ff99TBC XP Tracker:|r minimap button disabled (%s).", err))
        return
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(1, function()
            ensureMinimapButton(try + 1)
        end)
    else
        local err = ok and tostring(reason or "timer unavailable") or tostring(created or "timer unavailable")
        print(format("|cff33ff99TBC XP Tracker:|r minimap button disabled (%s).", err))
    end
end

local function refreshPauseButton()
    if ui.pauseButton then
        if state.paused then
            ui.pauseButton:SetText("Resume")
        else
            ui.pauseButton:SetText("Pause")
        end
    end
end

local function savePosition()
    if not db or not ui.frame then
        return
    end

    local point, _, relativePoint, x, y = ui.frame:GetPoint(1)
    db.point = point
    db.relativePoint = relativePoint
    db.x = round(x)
    db.y = round(y)
end

local function setTopLeftAnchor(widget, y)
    if not widget or not ui.frame then
        return
    end
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 12, y)
end

local function refreshTrackerSectionLayout()
    if not ui.frame then
        return
    end

    local inInstance = state.instance.current ~= nil

    if inInstance then
        ui.frame:SetHeight(292)

        if ui.sessionHeader then ui.sessionHeader:Hide() end
        if ui.gained then ui.gained:Hide() end
        if ui.rate then ui.rate:Hide() end
        if ui.estimate then ui.estimate:Hide() end
        if ui.toLevel then ui.toLevel:Hide() end
        if ui.dividerTop then ui.dividerTop:Hide() end

        if ui.instanceHeader then ui.instanceHeader:Show() end
        if ui.instanceCurrentTitle then ui.instanceCurrentTitle:Show() end
        if ui.instanceCurrentStats then ui.instanceCurrentStats:Show() end
        if ui.instancePreviousTitle then ui.instancePreviousTitle:Show() end
        if ui.instancePreviousStats then ui.instancePreviousStats:Show() end
        if ui.dividerMiddle then ui.dividerMiddle:Show() end

        setTopLeftAnchor(ui.instanceHeader, -28)
        setTopLeftAnchor(ui.instanceCurrentTitle, -44)
        setTopLeftAnchor(ui.instanceCurrentStats, -60)
        setTopLeftAnchor(ui.instancePreviousTitle, -76)
        setTopLeftAnchor(ui.instancePreviousStats, -92)

        if ui.dividerMiddle then
            ui.dividerMiddle:ClearAllPoints()
            ui.dividerMiddle:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 10, -110)
            ui.dividerMiddle:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -10, -110)
        end

        if ui.resetButton then
            ui.resetButton:ClearAllPoints()
            ui.resetButton:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 12, -124)
        end
        if ui.pauseButton then
            ui.pauseButton:ClearAllPoints()
            ui.pauseButton:SetPoint("TOP", ui.frame, "TOP", 0, -124)
        end
        if ui.hideButton then
            ui.hideButton:ClearAllPoints()
            ui.hideButton:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -12, -124)
        end
        if ui.reportChannelLabel then
            setTopLeftAnchor(ui.reportChannelLabel, -156)
        end
        if ui.reportChannelDropdown and ui.reportChannelLabel then
            ui.reportChannelDropdown:ClearAllPoints()
            ui.reportChannelDropdown:SetPoint("TOPLEFT", ui.reportChannelLabel, "BOTTOMLEFT", -10, -2)
        end
        if ui.sendButton then
            ui.sendButton:ClearAllPoints()
            ui.sendButton:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -12, -168)
        end
    else
        ui.frame:SetHeight(292)

        if ui.sessionHeader then ui.sessionHeader:Show() end
        if ui.gained then ui.gained:Show() end
        if ui.rate then ui.rate:Show() end
        if ui.estimate then ui.estimate:Show() end
        if ui.toLevel then ui.toLevel:Show() end
        if ui.dividerTop then ui.dividerTop:Show() end

        if ui.instanceHeader then ui.instanceHeader:Hide() end
        if ui.instanceCurrentTitle then ui.instanceCurrentTitle:Hide() end
        if ui.instanceCurrentStats then ui.instanceCurrentStats:Hide() end
        if ui.instancePreviousTitle then ui.instancePreviousTitle:Hide() end
        if ui.instancePreviousStats then ui.instancePreviousStats:Hide() end
        if ui.dividerMiddle then ui.dividerMiddle:Hide() end

        setTopLeftAnchor(ui.sessionHeader, -28)
        setTopLeftAnchor(ui.gained, -44)
        setTopLeftAnchor(ui.rate, -60)
        setTopLeftAnchor(ui.estimate, -76)
        setTopLeftAnchor(ui.toLevel, -92)

        if ui.dividerTop then
            ui.dividerTop:ClearAllPoints()
            ui.dividerTop:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 10, -110)
            ui.dividerTop:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -10, -110)
        end

        if ui.resetButton then
            ui.resetButton:ClearAllPoints()
            ui.resetButton:SetPoint("TOPLEFT", ui.frame, "TOPLEFT", 12, -124)
        end
        if ui.pauseButton then
            ui.pauseButton:ClearAllPoints()
            ui.pauseButton:SetPoint("TOP", ui.frame, "TOP", 0, -124)
        end
        if ui.hideButton then
            ui.hideButton:ClearAllPoints()
            ui.hideButton:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -12, -124)
        end
        if ui.reportChannelLabel then
            setTopLeftAnchor(ui.reportChannelLabel, -156)
        end
        if ui.reportChannelDropdown and ui.reportChannelLabel then
            ui.reportChannelDropdown:ClearAllPoints()
            ui.reportChannelDropdown:SetPoint("TOPLEFT", ui.reportChannelLabel, "BOTTOMLEFT", -10, -2)
        end
        if ui.sendButton then
            ui.sendButton:ClearAllPoints()
            ui.sendButton:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -12, -168)
        end
    end

    if ui.whisperTargetLabel and ui.reportChannelDropdown then
        ui.whisperTargetLabel:ClearAllPoints()
        ui.whisperTargetLabel:SetPoint("TOPLEFT", ui.reportChannelDropdown, "BOTTOMLEFT", 10, -4)
    end
    if ui.whisperTargetDropdown and ui.whisperTargetLabel then
        ui.whisperTargetDropdown:ClearAllPoints()
        ui.whisperTargetDropdown:SetPoint("TOPLEFT", ui.whisperTargetLabel, "BOTTOMLEFT", -10, -2)
    end
end

local function updateTexts()
    if not ui.frame then
        return
    end

    refreshTrackerSectionLayout()

    local rollingRate = getRollingRate()
    local sessionElapsed = getActiveTime() - state.sessionStart
    local rateText = formatNumber(rollingRate)
    local sessionText = formatDuration(sessionElapsed)
    local sessionRepText = formatSignedNumber(state.totalReputation)
    local sessionRepTypeText = getSessionReputationTypeText()
    local hasSessionRepType = sessionRepTypeText ~= "-"
    local canGainXP = canPlayerGainXPNow()

    if state.paused then
        rateText = rateText .. " (paused)"
        sessionText = sessionText .. " (paused)"
    end

    if canGainXP then
        ui.gained:SetText("Session XP: " .. formatNumber(state.totalXP) .. " | Rep: " .. sessionRepText)
        ui.rate:SetText("Session Rate: " .. rateText .. "/h")
        ui.estimate:SetText("Session Time: " .. sessionText)

        local currentXP = tonumber(UnitXP("player")) or state.lastXP or 0
        local maxXP = tonumber(UnitXPMax("player")) or state.lastXPMax or 0
        local toLevel = max(0, maxXP - currentXP)
        if hasSessionRepType then
            ui.toLevel:SetText("Reputation: " .. sessionRepTypeText)
        else
            ui.toLevel:SetText("To Next Level: " .. formatNumber(toLevel))
        end
    else
        ui.gained:SetText("Session Rep: " .. sessionRepText)
        ui.rate:SetText("Rep Factions: " .. tostring(getSessionReputationFactionCount()))
        ui.estimate:SetText("Session Time: " .. sessionText)
        if hasSessionRepType then
            ui.toLevel:SetText("Reputation: " .. sessionRepTypeText)
        else
            ui.toLevel:SetText("")
        end
    end

    if ui.instanceCurrentTitle and ui.instanceCurrentStats and ui.instancePreviousTitle and ui.instancePreviousStats then
        local currentRecord = state.instance.current
        local currentStats = getInstanceStats(currentRecord)
        if currentStats then
            ui.instanceCurrentTitle:SetText("Current: " .. currentStats.name)
            if canGainXP and isXPEnabledForRecord(currentRecord) then
                ui.instanceCurrentStats:SetText(format(
                    "XP: %s | Rep: %s | XP/h: %s | Time: %s",
                    formatNumber(currentStats.totalXP),
                    formatSignedNumber(currentStats.totalReputation),
                    formatNumber(currentStats.rate),
                    formatDuration(currentStats.duration)
                ))
            else
                ui.instanceCurrentStats:SetText(format(
                    "Rep: %s | Type: %s | Time: %s",
                    formatSignedNumber(currentStats.totalReputation),
                    getReputationTypeText(currentRecord),
                    formatDuration(currentStats.duration)
                ))
            end
        else
            ui.instanceCurrentTitle:SetText("Current: not in instance")
            if canGainXP then
                ui.instanceCurrentStats:SetText("XP: 0 | Rep: 0 | XP/h: 0 | Time: 00:00:00")
            else
                ui.instanceCurrentStats:SetText("Rep: 0 | Type: - | Time: 00:00:00")
            end
        end

        local previousRecord = state.instance.previous
        if isSameInstanceRun(state.instance.current, previousRecord) then
            previousRecord = nil
        end
        local previousStats = getInstanceStats(previousRecord)
        if previousStats then
            ui.instancePreviousTitle:SetText("Previous: " .. previousStats.name)
            if canGainXP and isXPEnabledForRecord(previousRecord) then
                ui.instancePreviousStats:SetText(format(
                    "XP: %s | Rep: %s | XP/h: %s | Time: %s",
                    formatNumber(previousStats.totalXP),
                    formatSignedNumber(previousStats.totalReputation),
                    formatNumber(previousStats.rate),
                    formatDuration(previousStats.duration)
                ))
            else
                ui.instancePreviousStats:SetText(format(
                    "Rep: %s | Type: %s | Time: %s",
                    formatSignedNumber(previousStats.totalReputation),
                    getReputationTypeText(previousRecord),
                    formatDuration(previousStats.duration)
                ))
            end
        else
            ui.instancePreviousTitle:SetText("Previous: none")
            if canGainXP then
                ui.instancePreviousStats:SetText("XP: 0 | Rep: 0 | XP/h: 0 | Time: 00:00:00")
            else
                ui.instancePreviousStats:SetText("Rep: 0 | Type: - | Time: 00:00:00")
            end
        end
    end

    if ui.historyFrame and ui.historyFrame:IsShown() and refreshHistoryModal and not isHistoryDropdownOpen() then
        refreshHistoryModal()
    end

    refreshPauseButton()
end

local function setPaused(paused)
    if paused and not state.paused then
        state.paused = true
        state.pauseStartedAt = time()
    elseif not paused and state.paused then
        local pauseDuration = max(0, time() - state.pauseStartedAt)
        state.pausedTotal = state.pausedTotal + pauseDuration
        state.pauseStartedAt = 0
        state.paused = false
    end

    updateTexts()
end

local function resetSession(preserveInstanceData)
    state.sessionStart = getActiveTime()
    state.totalXP = 0
    state.totalReputation = 0
    state.lastXP = tonumber(UnitXP("player")) or 0
    state.lastXPMax = tonumber(UnitXPMax("player")) or 0
    state.lastLevel = tonumber(UnitLevel("player")) or 0
    state.lastReputation = getFactionReputationSnapshot()
    state.sessionReputationByFaction = {}
    state.history = {}
    if not preserveInstanceData then
        state.instance.current = nil
        state.instance.previous = nil
    end
    state.initialized = true

    refreshInstanceContext()
    persistInstanceData()
    updateTexts()
end

local function handleXPUpdate()
    if not state.initialized then
        return
    end
    refreshInstanceContext()

    local currentXP = tonumber(UnitXP("player")) or state.lastXP or 0
    local currentXPMax = tonumber(UnitXPMax("player")) or state.lastXPMax or 0
    local currentLevel = tonumber(UnitLevel("player")) or state.lastLevel or 0

    if state.paused then
        state.lastXP = currentXP
        state.lastXPMax = currentXPMax
        state.lastLevel = currentLevel
        updateTexts()
        return
    end

    local gained = 0

    if currentLevel == state.lastLevel then
        gained = currentXP - state.lastXP
        if gained < 0 then
            gained = 0
        end
    elseif currentLevel > state.lastLevel then
        gained = (state.lastXPMax - state.lastXP) + currentXP
        if gained < 0 then
            gained = 0
        end
    end

    if gained > 0 then
        addGain(gained)
        if state.instance.current then
            state.instance.current.totalXP = state.instance.current.totalXP + gained
            persistInstanceData()
        end
    end

    state.lastXP = currentXP
    state.lastXPMax = currentXPMax
    state.lastLevel = currentLevel

    updateTexts()
end

local function handleReputationUpdate()
    local snapshot = getFactionReputationSnapshot()
    local previous = state.lastReputation or {}
    local totalDelta = 0
    local deltaByFaction = {}

    for key, value in pairs(snapshot) do
        local oldValue = previous[key]
        if oldValue ~= nil then
            local delta = value - oldValue
            if delta ~= 0 then
                totalDelta = totalDelta + delta
                deltaByFaction[key] = delta
            end
        end
    end

    state.lastReputation = snapshot

    if totalDelta == 0 or state.paused then
        return
    end

    state.totalReputation = floor((tonumber(state.totalReputation) or 0) + totalDelta)
    if type(state.sessionReputationByFaction) ~= "table" then
        state.sessionReputationByFaction = {}
    end
    for factionName, delta in pairs(deltaByFaction) do
        local current = floor(tonumber(state.sessionReputationByFaction[factionName]) or 0)
        local updated = current + delta
        if updated == 0 then
            state.sessionReputationByFaction[factionName] = nil
        else
            state.sessionReputationByFaction[factionName] = updated
        end
    end

    if state.instance.current then
        state.instance.current.totalReputation = floor((tonumber(state.instance.current.totalReputation) or 0) + totalDelta)
        if type(state.instance.current.reputationByFaction) ~= "table" then
            state.instance.current.reputationByFaction = {}
        end

        for factionName, delta in pairs(deltaByFaction) do
            local current = floor(tonumber(state.instance.current.reputationByFaction[factionName]) or 0)
            local updated = current + delta
            if updated == 0 then
                state.instance.current.reputationByFaction[factionName] = nil
            else
                state.instance.current.reputationByFaction[factionName] = updated
            end
        end
        persistInstanceData()
    end

    updateTexts()
end

hidePanel = function()
    if ui.frame then
        ui.frame:Hide()
    end

    if db then
        db.hidden = true
    end
end

showPanel = function(center)
    if not ui.frame then
        return
    end

    if center then
        ui.frame:ClearAllPoints()
        ui.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        savePosition()
    end

    ui.frame:Show()

    if db then
        db.hidden = false
    end
end

local function createUI()
    if ui.frame then
        return
    end

    local frame = CreateFrame("Frame", "TBCXPTrackerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    frame:SetSize(278, 352)
    frame:SetClampedToScreen(true)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        frame:SetBackdropColor(0.02, 0.03, 0.04, 0.92)
    end

    local point = (db and db.point) or "CENTER"
    local relativePoint = (db and db.relativePoint) or "CENTER"
    local x = (db and db.x) or 0
    local y = (db and db.y) or 0
    frame:SetPoint(point, UIParent, relativePoint, x, y)

    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText("TBC XP Tracker")
    title:SetTextColor(1, 0.82, 0.1)

    local sessionHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessionHeader:SetPoint("TOPLEFT", 12, -28)
    sessionHeader:SetText("SESSION")
    sessionHeader:SetTextColor(0.7, 0.82, 1)

    local gained = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    gained:SetPoint("TOPLEFT", 12, -44)
    gained:SetJustifyH("LEFT")
    gained:SetText("Session XP: 0")

    local rate = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rate:SetPoint("TOPLEFT", 12, -60)
    rate:SetJustifyH("LEFT")
    rate:SetText("Session Rate: 0/h")

    local session = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    session:SetPoint("TOPLEFT", 12, -76)
    session:SetJustifyH("LEFT")
    session:SetText("Session Time: 00:00:00")

    local toLevel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    toLevel:SetPoint("TOPLEFT", 12, -92)
    toLevel:SetJustifyH("LEFT")
    toLevel:SetText("To Next Level: 0")

    local dividerTop = frame:CreateTexture(nil, "ARTWORK")
    dividerTop:SetColorTexture(1, 1, 1, 0.12)
    dividerTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -110)
    dividerTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -110)
    dividerTop:SetHeight(1)

    local instanceHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instanceHeader:SetPoint("TOPLEFT", 12, -120)
    instanceHeader:SetText("INSTANCE")
    instanceHeader:SetTextColor(0.7, 0.82, 1)

    local instanceCurrentTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instanceCurrentTitle:SetPoint("TOPLEFT", 12, -136)
    instanceCurrentTitle:SetJustifyH("LEFT")
    instanceCurrentTitle:SetText("Current: not in instance")

    local instanceCurrentStats = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instanceCurrentStats:SetPoint("TOPLEFT", 12, -152)
    instanceCurrentStats:SetJustifyH("LEFT")
    instanceCurrentStats:SetText("XP: 0 | Rep: 0 | XP/h: 0 | Time: 00:00:00")

    local instancePreviousTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instancePreviousTitle:SetPoint("TOPLEFT", 12, -168)
    instancePreviousTitle:SetJustifyH("LEFT")
    instancePreviousTitle:SetText("Previous: none")

    local instancePreviousStats = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instancePreviousStats:SetPoint("TOPLEFT", 12, -184)
    instancePreviousStats:SetJustifyH("LEFT")
    instancePreviousStats:SetText("XP: 0 | Rep: 0 | XP/h: 0 | Time: 00:00:00")

    local dividerMiddle = frame:CreateTexture(nil, "ARTWORK")
    dividerMiddle:SetColorTexture(1, 1, 1, 0.12)
    dividerMiddle:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -202)
    dividerMiddle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -202)
    dividerMiddle:SetHeight(1)

    local reportChannelLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reportChannelLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -248)
    reportChannelLabel:SetJustifyH("LEFT")
    reportChannelLabel:SetText("Report channel:")

    local reportChannelDropdown = CreateFrame("Frame", "TBCXPTrackerReportChannelDropdown", frame, "UIDropDownMenuTemplate")
    reportChannelDropdown:SetPoint("TOPLEFT", reportChannelLabel, "BOTTOMLEFT", -10, -2)
    local whisperTargetLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    whisperTargetLabel:SetJustifyH("LEFT")
    whisperTargetLabel:SetText("Whisper target:")

    local whisperTargetDropdown = CreateFrame("Frame", "TBCXPTrackerWhisperTargetDropdown", frame, "UIDropDownMenuTemplate")

    local resetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    resetButton:SetSize(64, 20)
    resetButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -216)
    resetButton:SetText("Reset")
    resetButton:SetScript("OnClick", function()
        resetSession()
    end)

    local hideButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    hideButton:SetSize(64, 20)
    hideButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -216)
    hideButton:SetText("Hide")
    hideButton:SetScript("OnClick", function()
        hidePanel()
    end)

    local pauseButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    pauseButton:SetSize(72, 20)
    pauseButton:SetPoint("TOP", frame, "TOP", 0, -216)
    pauseButton:SetScript("OnClick", function()
        if state.paused then
            setPaused(false)
        else
            setPaused(true)
        end
    end)

    local sendButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    sendButton:SetSize(64, 20)
    sendButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -260)
    sendButton:SetText("Send")
    sendButton:SetScript("OnClick", function()
        sendReport(nil)
    end)

    whisperTargetLabel:SetPoint("TOPLEFT", reportChannelDropdown, "BOTTOMLEFT", 10, -4)
    whisperTargetDropdown:SetPoint("TOPLEFT", whisperTargetLabel, "BOTTOMLEFT", -10, -2)

    ui.frame = frame
    ui.gained = gained
    ui.sessionHeader = sessionHeader
    ui.rate = rate
    ui.estimate = session
    ui.toLevel = toLevel
    ui.dividerTop = dividerTop
    ui.instanceHeader = instanceHeader
    ui.instanceCurrentTitle = instanceCurrentTitle
    ui.instanceCurrentStats = instanceCurrentStats
    ui.instancePreviousTitle = instancePreviousTitle
    ui.instancePreviousStats = instancePreviousStats
    ui.dividerMiddle = dividerMiddle
    ui.reportChannelLabel = reportChannelLabel
    ui.reportChannelDropdown = reportChannelDropdown
    ui.whisperTargetLabel = whisperTargetLabel
    ui.whisperTargetDropdown = whisperTargetDropdown
    ui.resetButton = resetButton
    ui.hideButton = hideButton
    ui.pauseButton = pauseButton
    ui.sendButton = sendButton
    refreshWhisperTargetDropdownText()
    initializeReportChannelDropdown()
    initializeWhisperTargetDropdown()
    refreshPauseButton()
end

local function initializeAddon()
    if addonReady then
        return
    end

    if not TBCXPTrackerDB then
        TBCXPTrackerDB = {}
    end

    db = TBCXPTrackerDB
    if db.reportChannel == "WHISPER" then
        db.reportChannel = "WHISPER_TARGET"
    end
    db.reportChannel = db.reportChannel or resolveReportChannel(db.reportChannel or "") or "SELF"
    if not REPORT_CHANNEL_LABELS[db.reportChannel] then
        db.reportChannel = "SELF"
    end

    if db.historyReportChannel == "WHISPER" then
        db.historyReportChannel = "WHISPER_TARGET"
    end
    if not REPORT_CHANNEL_LABELS[db.historyReportChannel] then
        db.historyReportChannel = resolveReportChannel(db.historyReportChannel or "")
    end
    if not REPORT_CHANNEL_LABELS[db.historyReportChannel] then
        db.historyReportChannel = db.reportChannel
    end
    if not REPORT_CHANNEL_LABELS[db.historyReportChannel] then
        db.historyReportChannel = "SELF"
    end

    if db.minimapAngle == nil and db.minimapX and db.minimapY then
        db.minimapAngle = deg(atan2(tonumber(db.minimapY) or 0, tonumber(db.minimapX) or 0))
    end
    db.minimapAngle = normalizeMinimapAngle(db.minimapAngle)
    db.reportWhisperTarget = trim(db.reportWhisperTarget or "")
    restoreInstanceData()
    migrateLegacyInstanceHistory()
    createUI()
    resetSession(true)

    if db.hidden then
        hidePanel()
    else
        showPanel(false)
    end

    addonReady = true
    print("|cff33ff99TBC XP Tracker:|r loaded. Use /xph to open history.")
end

NS.state = state
NS.ui = ui

NS.trim = trim
NS.normalizeCommand = normalizeCommand
NS.splitCommand = splitCommand
NS.resolveReportChannel = resolveReportChannel
NS.getReportChannelDescription = getReportChannelDescription

NS.initializeAddon = initializeAddon
NS.isAddonReady = function()
    return addonReady
end
NS.getDB = function()
    return db
end

NS.resetSession = resetSession
NS.hidePanel = hidePanel
NS.showPanel = showPanel
NS.setPaused = setPaused
NS.setReportChannel = setReportChannel
NS.sendReport = sendReport
NS.openHistoryModal = openHistoryModal
NS.toggleHistoryModal = toggleHistoryModal
NS.refreshHistoryModal = refreshHistoryModal

NS.handleXPUpdate = handleXPUpdate
NS.handleReputationUpdate = handleReputationUpdate
NS.refreshInstanceContext = refreshInstanceContext
NS.updateTexts = updateTexts

NS.sanitizeWhisperTarget = sanitizeWhisperTarget
NS.refreshWhisperTargetDropdownText = refreshWhisperTargetDropdownText
NS.refreshReportChannelDropdownText = refreshReportChannelDropdownText
NS.initializeWhisperTargetDropdown = initializeWhisperTargetDropdown

