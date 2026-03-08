local _, NS = ...

local format = string.format

SLASH_TBCXPTRACKER1 = "/xph"
SLASH_TBCXPTRACKER2 = "/tbcxp"
SlashCmdList["TBCXPTRACKER"] = function(msg)
    local state = NS.state
    local rawMsg = NS.trim and NS.trim(msg or "") or (msg or "")
    local rawCommand, rawArgument = "", ""
    if NS.splitCommand then
        rawCommand, rawArgument = NS.splitCommand(rawMsg)
    end
    local command = NS.normalizeCommand and NS.normalizeCommand(rawCommand) or ""
    local argument = NS.trim and NS.trim(rawArgument) or rawArgument

    if NS.isAddonReady and not NS.isAddonReady() then
        if NS.initializeAddon then
            local ok, err = pcall(NS.initializeAddon)
            if not ok then
                print(format("|cff33ff99TBC XP Tracker:|r failed to initialize (%s).", tostring(err)))
                print("|cff33ff99TBC XP Tracker:|r run /console scriptErrors 1 then /reload for details.")
                return
            end
        end
    end

    if type(NS.resetSession) ~= "function" or type(NS.openHistoryModal) ~= "function" then
        print("|cff33ff99TBC XP Tracker:|r core failed to load. Run /console scriptErrors 1 then /reload.")
        return
    end

    if command == "reset" then
        NS.resetSession(false)
        return
    end

    if command == "hide" then
        NS.hidePanel()
        return
    end

    if command == "show" then
        NS.showPanel(true)
        return
    end

    if command == "pause" then
        if state and state.paused then return end
        NS.setPaused(true)
        return
    end

    if command == "resume" then
        if state and not state.paused then return end
        NS.setPaused(false)
        return
    end

    if command == "channel" then
        if argument == "" then
            return
        end

        local channelName = argument
        if NS.splitCommand then
            channelName = NS.splitCommand(argument)
        end

        local resolved = NS.resolveReportChannel and NS.resolveReportChannel(channelName)
        if not resolved then
            return
        end

        NS.setReportChannel(resolved)
        return
    end

    if command == "report" then
        if argument == "" then
            NS.sendReport(nil)
            return
        end

        local channelName = argument
        if NS.splitCommand then
            channelName = NS.splitCommand(argument)
        end

        local resolved = NS.resolveReportChannel and NS.resolveReportChannel(channelName)
        if not resolved then
            return
        end

        NS.sendReport(resolved)
        return
    end

    if command == "history" then
        if NS.openHistoryModal then
            NS.openHistoryModal()
        end
        return
    end

    if command == "" then
        if NS.openHistoryModal then
            NS.openHistoryModal()
        end
        return
    end

end
