local module = {}

local CFG_PATH = "modern_bot_cfg.json"

local DEFAULTS = {
    master        = true,
    enabled       = false,
    debug_log     = false,
    pulse_btn_idx = 1,
    interval_min  = 30,
    interval_max  = 90,
    hold_min      = 2,
    hold_max      = 5,
    hold_enabled  = false,
    hold_btn_idx  = 1,
    hold_forward  = false,
    hold_back     = false,
    move_enabled  = false,
    move_charge_min    = 45,
    move_delay_min     = 10,
    move_delay_max     = 45,
    move_jump_min      = 2,
    move_jump_max      = 5,
    allow_training = false,
    auto_rematch   = false,
    player_side   = 0,  -- 0=Auto, 1=P1, 2=P2
}

local function make_defaults()
    local t = {}
    for k, v in pairs(DEFAULTS) do t[k] = v end
    return t
end

function module.load()
    local ok, data = pcall(json.load_file, CFG_PATH)
    if not ok or not data then return make_defaults() end
    local merged = make_defaults()
    for k, v in pairs(data) do
        if DEFAULTS[k] ~= nil then merged[k] = v end
    end
    return merged
end

function module.save()
    local data = {}
    for k, _ in pairs(DEFAULTS) do data[k] = module.cfg[k] end
    pcall(json.dump_file, CFG_PATH, data)
end

module.cfg = module.load()

return module
