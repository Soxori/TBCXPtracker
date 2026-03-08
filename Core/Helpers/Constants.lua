local _, NS = ...
NS = NS or {}

NS.Constants = NS.Constants or {}
local C = NS.Constants

C.RATE_HISTORY_SECONDS = 3600
C.MIN_RATE_SAMPLE_SECONDS = 5

C.REPORT_CHANNEL_ALIASES = {
    self = "SELF",
    localchat = "SELF",
    print = "SELF",
    say = "SAY",
    party = "PARTY",
    p = "PARTY",
    raid = "RAID",
    r = "RAID",
    guild = "GUILD",
    g = "GUILD",
    officer = "OFFICER",
    yell = "YELL",
    instance = "INSTANCE_CHAT",
    i = "INSTANCE_CHAT"
}

C.REPORT_CHANNEL_LABELS = {
    SELF = "self",
    WHISPER_TARGET = "whisper player",
    SAY = "say",
    PARTY = "party",
    RAID = "raid",
    GUILD = "guild",
    OFFICER = "officer",
    YELL = "yell",
    INSTANCE_CHAT = "instance"
}

C.REPORT_CHANNEL_CHOICES = {
    { value = "SELF", text = "self" },
    { value = "SAY", text = "say" },
    { value = "PARTY", text = "party" },
    { value = "RAID", text = "raid" },
    { value = "GUILD", text = "guild" },
    { value = "OFFICER", text = "officer" },
    { value = "YELL", text = "yell" },
    { value = "INSTANCE_CHAT", text = "instance" },
    { value = "WHISPER_TARGET", text = "whisper player" }
}
