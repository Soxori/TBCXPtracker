local _, NS = ...

local eventFrame = CreateFrame("Frame")
local elapsedSinceRefresh = 0
local REFRESH_INTERVAL_SECONDS = 1

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSinceRefresh = elapsedSinceRefresh + elapsed
    if elapsedSinceRefresh >= REFRESH_INTERVAL_SECONDS then
        elapsedSinceRefresh = 0
        local state = NS.state
        if state and state.initialized then
            if NS.refreshInstanceContext then
                NS.refreshInstanceContext()
            end
            if NS.updateTexts then
                NS.updateTexts()
            end
        elseif NS.isAddonReady and not NS.isAddonReady() and NS.initializeAddon then
            NS.initializeAddon()
        end
    end
end)

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        if NS.initializeAddon then
            NS.initializeAddon()
        end
        if NS.refreshInstanceContext then
            NS.refreshInstanceContext()
        end
        if NS.updateTexts then
            NS.updateTexts()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if NS.isAddonReady and NS.isAddonReady() then
            if NS.refreshInstanceContext then
                NS.refreshInstanceContext()
            end
            if NS.updateTexts then
                NS.updateTexts()
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        if NS.isAddonReady and NS.isAddonReady() then
            if NS.sanitizeWhisperTarget then
                NS.sanitizeWhisperTarget()
            end
            if NS.refreshWhisperTargetDropdownText then
                NS.refreshWhisperTargetDropdownText()
            end
            if NS.refreshReportChannelDropdownText then
                NS.refreshReportChannelDropdownText()
            end
            if NS.initializeWhisperTargetDropdown then
                NS.initializeWhisperTargetDropdown()
            end
        end
    elseif event == "PLAYER_XP_UPDATE" then
        if arg1 and arg1 ~= "player" then
            return
        end
        if NS.handleXPUpdate then
            NS.handleXPUpdate()
        end
    elseif event == "UPDATE_FACTION" then
        if NS.handleReputationUpdate then
            NS.handleReputationUpdate()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        if NS.handleXPUpdate then
            NS.handleXPUpdate()
        end
    end
end)

eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_XP_UPDATE")
eventFrame:RegisterEvent("UPDATE_FACTION")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
