local _, NS = ...
NS = NS or {}

NS.Helpers = NS.Helpers or {}
local H = NS.Helpers

local floor = math.floor
local max = math.max
local lower = string.lower
local gsub = string.gsub
local format = string.format

function H.round(n)
    if n >= 0 then
        return floor(n + 0.5)
    end
    return floor(n - 0.5)
end

function H.trim(text)
    text = text or ""
    text = gsub(text, "^%s+", "")
    text = gsub(text, "%s+$", "")
    return text
end

function H.normalizeCommand(text)
    return lower(H.trim(text))
end

function H.splitCommand(text)
    local command, rest = text:match("^(%S+)%s*(.-)$")
    if not command then
        return "", ""
    end
    return command, rest
end

function H.formatDuration(seconds)
    local total = max(0, floor(seconds))
    local hours = floor(total / 3600)
    local minutes = floor((total % 3600) / 60)
    local secs = total % 60
    return format("%02d:%02d:%02d", hours, minutes, secs)
end

function H.formatNumber(n)
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
