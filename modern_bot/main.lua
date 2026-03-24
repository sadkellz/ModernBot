log.debug("Loading EZ Claude...")

-- VK codes for keyboard bindings (WASD = directions, UIJKLO = buttons)
local VK = {
    W = 87, A = 65, S = 83, D = 68,
    U = 85, I = 73, O = 79,
    J = 74, K = 75, L = 76,
}

local BUTTONS = {
    {name = "Light (U)",  vk = VK.U},
    {name = "Medium (J)", vk = VK.J},
    {name = "Heavy (K)",  vk = VK.K},
    {name = "SP (I)",     vk = VK.I},
    {name = "DP (O)",     vk = VK.O},
    {name = "Auto (L)",   vk = VK.L},
}
local BUTTON_NAMES = {}
for i, b in ipairs(BUTTONS) do BUTTON_NAMES[i] = b.name end

---------------------------------------------------------------------------
-- Injected key state
---------------------------------------------------------------------------
local injected_vk = {}
local prev_injected_vk = {}

local function inject_key(vk)  injected_vk[vk] = true end
local function release_all()   injected_vk = {} end

---------------------------------------------------------------------------
-- Hook CheckDown/CheckTrigger/CheckRepeat on app.InputDeviceStateKeyboard
-- Returns true for keys we're injecting, making the game think they're pressed
---------------------------------------------------------------------------
local ptr_to_vk = {}
local app_kbd = sdk.find_type_definition("app.InputDeviceStateKeyboard")

local function resolve_vk(args3)
    local ptr = sdk.to_int64(args3) & 0xFFFFFFFF
    local vk = ptr_to_vk[ptr]
    if not vk then
        local obj = sdk.to_managed_object(args3)
        if obj then
            local ok, v = pcall(obj.get_field, obj, "Value")
            if ok then vk = v; ptr_to_vk[ptr] = vk end
        end
    end
    return vk
end

local function hook_kbd_method(name, check_trigger)
    local m = app_kbd and app_kbd:get_method(name)
    if not m then return end
    local cur_vk = nil
    sdk.hook(m,
        function(args) cur_vk = resolve_vk(args[3]) end,
        function(retval)
            if cur_vk and injected_vk[cur_vk] then
                if check_trigger and prev_injected_vk[cur_vk] then
                    return retval
                end
                return sdk.to_ptr(1)
            end
            return retval
        end
    )
end

hook_kbd_method("CheckDown", false)
hook_kbd_method("CheckTrigger", true)
hook_kbd_method("CheckRepeat", false)

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
local CFG_PATH = "modern_bot_cfg.json"
local cfg_defaults = {
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
    player_side   = 0,
}

local function load_cfg()
    local ok, data = pcall(json.load_file, CFG_PATH)
    if ok and data then
        local merged = {}
        for k, v in pairs(cfg_defaults) do merged[k] = v end
        for k, v in pairs(data) do
            if cfg_defaults[k] ~= nil then merged[k] = v end
        end
        return merged
    end
end

local cfg = load_cfg() or {}
for k, v in pairs(cfg_defaults) do
    if cfg[k] == nil then cfg[k] = v end
end

local function save_cfg()
    local data = {}
    for k, _ in pairs(cfg_defaults) do data[k] = cfg[k] end
    pcall(json.dump_file, CFG_PATH, data)
end

---------------------------------------------------------------------------
-- Forward declarations
---------------------------------------------------------------------------
local refresh_player_behaviors

---------------------------------------------------------------------------
-- Match state + auto side detection
---------------------------------------------------------------------------
local fbattle = nil
local in_match = false
local frame = 0
local detected_side = nil
local detect_phase = 0

local function read_player_input(idx)
    if not fbattle then return nil end
    local ok, p = pcall(fbattle.call, fbattle, "GetPlayer", idx)
    if not ok or not p then return nil end
    local ok2, inp = pcall(p.call, p, "get_InputNew")
    return ok2 and inp or nil
end

local function try_detect_side()
    if cfg.player_side ~= 0 then
        detected_side = cfg.player_side
        refresh_player_behaviors()
        return
    end

    -- Try getOnlineCpuBattleSelfSideIndex first (works for online + vs CPU)
    local bf_type = sdk.find_type_definition("app.battle.bBattleFlow")
    local bf_singleton = bf_type and sdk.get_managed_singleton("app.battle.bBattleFlow")
    if bf_singleton then
        local ok, idx = pcall(bf_singleton.call, bf_singleton, "getOnlineCpuBattleSelfSideIndex", false)
        if ok and idx then
            detected_side = idx + 1  -- 0-indexed -> 1-indexed
            refresh_player_behaviors()
            log.debug("[bot] Detected side via bBattleFlow: P" .. detected_side)
            return
        end
    end

    -- Fallback: probe with S key
    if detect_phase == 0 then
        inject_key(VK.S)
        detect_phase = 1
    elseif detect_phase == 1 then
        local p1 = read_player_input(0) or 0
        local p2 = read_player_input(1) or 0
        release_all()
        if (p1 & 0x002) ~= 0 and (p2 & 0x002) == 0 then
            detected_side = 1
            refresh_player_behaviors()
            log.debug("[bot] Detected side via probe: P1")
        elseif (p2 & 0x002) ~= 0 and (p1 & 0x002) == 0 then
            detected_side = 2
            refresh_player_behaviors()
            log.debug("[bot] Detected side via probe: P2")
        else
            detect_phase = 0
        end
    end
end

local function reset_state()
    release_all()
    detected_side = nil
    detect_phase = 0
end

local function check_match()
    if not fbattle then
        if in_match then
            in_match = false
            reset_state()
        end
        return false
    end
    local ok, p = pcall(fbattle.call, fbattle, "GetPlayer", 0)
    local now = ok and p ~= nil
    if now and not in_match then
        in_match = true
        frame = 0
        reset_state()
    elseif not now and in_match then
        in_match = false
        reset_state()
    end
    return in_match
end

---------------------------------------------------------------------------
-- Facing detection
---------------------------------------------------------------------------
local player_behaviors = {nil, nil}

refresh_player_behaviors = function()
    player_behaviors = {nil, nil}
    local scene_mgr = sdk.get_native_singleton("via.SceneManager")
    if not scene_mgr then return end
    local scene = sdk.call_native_func(scene_mgr,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    local transform = scene:call("get_FirstTransform")
    local count = 0
    while transform and count < 500 do
        count = count + 1
        local go = transform:call("get_GameObject")
        if go then
            local pb = go:call("getComponent(System.Type)", sdk.typeof("app.PlayerBehavior"))
            if pb then
                if not player_behaviors[1] then
                    player_behaviors[1] = pb
                elseif not player_behaviors[2] then
                    player_behaviors[2] = pb
                    break
                end
            end
        end
        transform = transform:call("get_Next")
    end
end

local function get_my_index()
    return detected_side or cfg.player_side or 1
end

local function get_facing()
    local idx = get_my_index()
    local pb = player_behaviors[idx]
    if not pb then
        refresh_player_behaviors()
        pb = player_behaviors[idx]
        if not pb then return nil end
    end
    local ok, mirror = pcall(pb.call, pb, "get_IsMirror")
    if not ok then
        refresh_player_behaviors()
        pb = player_behaviors[idx]
        if not pb then return nil end
        ok, mirror = pcall(pb.call, pb, "get_IsMirror")
        if not ok then return nil end
    end
    return mirror
end

---------------------------------------------------------------------------
-- Pulse timer
---------------------------------------------------------------------------
local pulse_timer = 0
local pulse_holding = 0
local cur_interval = 60
local cur_hold = 3

local function tick_pulse()
    if not cfg.enabled then return end
    if pulse_holding > 0 then
        inject_key(BUTTONS[cfg.pulse_btn_idx].vk)
        pulse_holding = pulse_holding - 1
        return
    end
    pulse_timer = pulse_timer + 1
    if pulse_timer >= cur_interval then
        pulse_timer = 0
        cur_hold = math.random(cfg.hold_min, cfg.hold_max)
        cur_interval = math.random(cfg.interval_min, cfg.interval_max)
        pulse_holding = cur_hold
        inject_key(BUTTONS[cfg.pulse_btn_idx].vk)
        if cfg.debug_log then
            log.debug(string.format("[bot] Pulse %s (hold %df, next %df)",
                BUTTONS[cfg.pulse_btn_idx].name, cur_hold, cur_interval))
        end
    end
end

---------------------------------------------------------------------------
-- Continuous holds
---------------------------------------------------------------------------
local function apply_holds()
    if cfg.hold_enabled then
        inject_key(BUTTONS[cfg.hold_btn_idx].vk)
    end

    local mirror = get_facing()
    if cfg.debug_log and (cfg.hold_forward or cfg.hold_back) and frame % 60 == 1 then
        log.debug("[bot] side=P" .. get_my_index() .. " mirror=" .. tostring(mirror))
    end

    if cfg.hold_forward then
        if mirror then
            inject_key(VK.D)
        else
            inject_key(VK.A)
        end
    end
    if cfg.hold_back then
        if mirror then
            inject_key(VK.A)
        else
            inject_key(VK.D)
        end
    end
end

---------------------------------------------------------------------------
-- On Frame
---------------------------------------------------------------------------
re.on_frame(function()
    
end)

---------------------------------------------------------------------------
-- Main hook
---------------------------------------------------------------------------
sdk.hook(
    sdk.find_type_definition("app.FBattleInput"):get_method("confirmBattleInput"),
    function(args) fbattle = sdk.to_managed_object(args[2]) end,
    function(retval)
        if not cfg.master then release_all() return retval end
        if not check_match() then return retval end
        frame = frame + 1

        if not detected_side then
            try_detect_side()
            return retval
        end

        prev_injected_vk = {}
        for vk, _ in pairs(injected_vk) do prev_injected_vk[vk] = true end
        release_all()

        tick_pulse()
        apply_holds()

        return retval
    end
)

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
re.on_draw_ui(function()
    if imgui.tree_node("Modern Bot") then
        local changed

        changed, cfg.master = imgui.checkbox("Master Enable", cfg.master)

        imgui.separator()
        changed, cfg.player_side = imgui.combo("Player Side", cfg.player_side, {"Auto", "P1", "P2"})

        imgui.separator()
        changed, cfg.enabled = imgui.checkbox("Pulse Button", cfg.enabled)
        changed, cfg.pulse_btn_idx = imgui.combo("Pulse Which", cfg.pulse_btn_idx, BUTTON_NAMES)
        changed, cfg.interval_min = imgui.slider_int("Interval Min (f)", cfg.interval_min, 1, 300)
        changed, cfg.interval_max = imgui.slider_int("Interval Max (f)", cfg.interval_max, 1, 300)
        if cfg.interval_max < cfg.interval_min then cfg.interval_max = cfg.interval_min end
        changed, cfg.hold_min = imgui.slider_int("Hold Min (f)", cfg.hold_min, 1, 30)
        changed, cfg.hold_max = imgui.slider_int("Hold Max (f)", cfg.hold_max, 1, 30)
        if cfg.hold_max < cfg.hold_min then cfg.hold_max = cfg.hold_min end

        imgui.separator()
        changed, cfg.hold_enabled = imgui.checkbox("Hold Button", cfg.hold_enabled)
        changed, cfg.hold_btn_idx = imgui.combo("Hold Which", cfg.hold_btn_idx, BUTTON_NAMES)
        changed, cfg.hold_forward = imgui.checkbox("Hold Forward", cfg.hold_forward)
        changed, cfg.hold_back = imgui.checkbox("Hold Back", cfg.hold_back)

        imgui.separator()
        changed, cfg.debug_log = imgui.checkbox("Debug Log", cfg.debug_log)
        if imgui.button("Save") then save_cfg() end
        imgui.same_line()
        if imgui.button("Load") then
            local loaded = load_cfg()
            if loaded then for k, v in pairs(loaded) do cfg[k] = v end end
        end

        imgui.spacing()
        local status = in_match and "IN MATCH" or "NO MATCH"
        local side_str = detected_side and ("P" .. detected_side .. " (auto)") or
                         cfg.player_side ~= 0 and ("P" .. cfg.player_side) or "..."
        imgui.text(status .. " | " .. side_str .. " | f" .. frame)

        imgui.tree_pop()
    end
end)

log.debug("Modern Bot Ready")
