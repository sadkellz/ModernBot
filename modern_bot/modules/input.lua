local module = {}

---------------------------------------------------------------------------
-- VK codes & button definitions
---------------------------------------------------------------------------
local VK = {
    W = 87, A = 65, S = 83, D = 68, F = 70,
    U = 85, I = 73, O = 79,
    J = 74, K = 75, L = 76,
    ESCAPE = 0x1B,
}

local BUTTONS = {
    {name = "Light",  vk = VK.U},
    {name = "Medium", vk = VK.J},
    {name = "Heavy",  vk = VK.K},
    {name = "SP",     vk = VK.I},
    {name = "DP",     vk = VK.O},
    {name = "Auto",   vk = VK.L},
}

local BUTTON_NAMES = {}
for i, b in ipairs(BUTTONS) do BUTTON_NAMES[i] = b.name end

module.BUTTONS = BUTTONS
module.BUTTON_NAMES = BUTTON_NAMES

---------------------------------------------------------------------------
-- Injected key state
---------------------------------------------------------------------------
local injected_vk = {}
local prev_injected_vk = {}

local function inject_key(vk)  injected_vk[vk] = true end
local function release_all()   injected_vk = {} end

module.inject_key = inject_key
module.release_all = release_all
module.VK = VK

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
-- Pulse timer
---------------------------------------------------------------------------
local pulse_timer = 0
local pulse_holding = 0
local cur_interval = 60
local cur_hold = 3
local pulse_auto_active = false

local function tick_pulse(cfg)
    if not cfg.enabled then return end
    if pulse_holding > 0 then
        inject_key(BUTTONS[cfg.pulse_btn_idx].vk)
        if pulse_auto_active then inject_key(VK.L) end
        pulse_holding = pulse_holding - 1
        return
    end
    pulse_timer = pulse_timer + 1
    if pulse_timer >= cur_interval then
        pulse_timer = 0
        cur_hold = math.random(cfg.hold_min, cfg.hold_max)
        cur_interval = math.random(cfg.interval_min, cfg.interval_max)
        pulse_holding = cur_hold
        pulse_auto_active = cfg.pulse_auto_chance > 0 and math.random(1, 100) <= cfg.pulse_auto_chance
        inject_key(BUTTONS[cfg.pulse_btn_idx].vk)
        if pulse_auto_active then inject_key(VK.L) end
    end
end

---------------------------------------------------------------------------
-- Continuous holds
---------------------------------------------------------------------------
local function apply_holds(cfg, battle)
    if cfg.hold_enabled then
        inject_key(BUTTONS[cfg.hold_btn_idx].vk)
    end

    if not cfg.hold_forward and not cfg.hold_back then return end

    local facing_right = battle.get_facing(cfg.player_side)

    -- facing_right=true: forward=D, back=A
    -- facing_right=false (facing left): forward=A, back=D
    local fwd_key = facing_right and VK.D or VK.A
    local back_key = facing_right and VK.A or VK.D

    if cfg.hold_forward then inject_key(fwd_key) end
    if cfg.hold_back then inject_key(back_key) end
end

---------------------------------------------------------------------------
-- Move sequence (charge down → jump + attack when actionable)
---------------------------------------------------------------------------
local MOVE_PHASE_CHARGE = 1
local MOVE_PHASE_JUMP   = 2

local move_phase = MOVE_PHASE_CHARGE
local move_ready_timer = 0    -- frames actionable after charge complete
local move_jump_timer = 0
local move_delay_target = 0
local move_current_buttons = nil
local move_jump_dir = nil  -- nil=neutral, VK.A=left, VK.D=right
local move_jump_hold = 0   -- randomized hold duration for this jump

local MOVE_OPTIONS = {
    { BUTTONS[1].vk },                    -- Light
    { BUTTONS[2].vk },                    -- Medium
    { BUTTONS[3].vk },                    -- Heavy
    { BUTTONS[2].vk, BUTTONS[3].vk },     -- Medium + Heavy
}

local JUMP_DIRS = { "neutral", "forward", "back" }

local ACTIONABLE_STATES = {
    [0] = true,   -- FOOTWORK
    [1] = true,   -- SIT
    [3] = true,   -- SITD
    [4] = true,   -- STAND
    [8] = true,   -- WALK
    [9] = true,   -- DUCK_WALK
}

local function tick_move(cfg, battle)
    if not cfg.move_enabled then
        move_phase = MOVE_PHASE_CHARGE

        move_ready_timer = 0
        move_jump_timer = 0
        move_delay_target = 0
        move_current_buttons = nil
        move_jump_dir = nil
        move_jump_hold = 0
        return
    end

    if move_phase == MOVE_PHASE_CHARGE then
        -- Hold down-back while charging
        inject_key(VK.S)
        local facing_right = battle.get_facing()
        local back_key = facing_right and VK.A or VK.D
        inject_key(back_key)



        -- Check if actionable AND charge is complete (read from game state)
        local act_st = battle.get_act_st()
        if act_st and ACTIONABLE_STATES[act_st] and battle.is_charge_complete() then
            move_ready_timer = move_ready_timer + 1

            -- Pick a delay target on first ready frame
            if move_delay_target == 0 then
                move_delay_target = math.random(cfg.move_delay_min, cfg.move_delay_max)
            end

            -- Time to execute
            if move_ready_timer >= move_delay_target then
                move_phase = MOVE_PHASE_JUMP
                move_jump_timer = 0
                move_current_buttons = MOVE_OPTIONS[math.random(1, #MOVE_OPTIONS)]
                move_jump_dir = JUMP_DIRS[math.random(1, #JUMP_DIRS)]
                move_jump_hold = math.random(cfg.move_jump_min, cfg.move_jump_max)
            end
        elseif not (act_st and ACTIONABLE_STATES[act_st]) then
            -- Not actionable: reset ready timer but keep charge timer
            move_ready_timer = 0
            move_delay_target = 0
        end

    elseif move_phase == MOVE_PHASE_JUMP then
        -- Jump + attack + direction (all simultaneous)
        move_jump_timer = move_jump_timer + 1
        inject_key(VK.W)
        if move_jump_dir ~= "neutral" then
            local facing_right = battle.get_facing()
            local fwd_key = facing_right and VK.D or VK.A
            local back_key = facing_right and VK.A or VK.D
            inject_key(move_jump_dir == "forward" and fwd_key or back_key)
        end
        for _, vk in ipairs(move_current_buttons) do
            inject_key(vk)
        end

        if move_jump_timer >= move_jump_hold then
            -- Back to charging
            move_phase = MOVE_PHASE_CHARGE
    
            move_ready_timer = 0
            move_delay_target = 0
            move_current_buttons = nil
            move_jump_dir = nil
            move_jump_hold = 0
        end
    end
end

---------------------------------------------------------------------------
-- Wakeup Super (on GETUP, randomly pick SA1/2/3 based on gauge)
---------------------------------------------------------------------------
local wakeup_super_level = 0
local wakeup_super_mash_timer = 0
local wakeup_super_mash_target = 0
local wakeup_super_pressing = false
local wakeup_super_getup_frame = 0
local wakeup_super_start_delay = 0
local ACT_ST_GETUP = 35

local function pick_super_level(gauge, cfg)
    local bars = math.floor(gauge / 10000)
    if bars <= 0 then return 0 end
    local options = {}
    if bars >= 1 and cfg.wakeup_sa1 then options[#options + 1] = 1 end
    if bars >= 2 and cfg.wakeup_sa2 then options[#options + 1] = 2 end
    if bars >= 3 and cfg.wakeup_sa3 then options[#options + 1] = 3 end
    if #options == 0 then return 0 end
    return options[math.random(1, #options)]
end

local function tick_wakeup_super(cfg, battle)
    if not cfg.wakeup_super_enabled then
        wakeup_super_level = 0
        wakeup_super_frame = 0
        return
    end

    local act_st = battle.get_act_st()

    if act_st ~= ACT_ST_GETUP then
        wakeup_super_level = 0
        wakeup_super_mash_timer = 0
        wakeup_super_mash_target = 0
        wakeup_super_pressing = false
        wakeup_super_getup_frame = 0
        wakeup_super_start_delay = 0
        return
    end

    wakeup_super_getup_frame = wakeup_super_getup_frame + 1

    if wakeup_super_level == -1 then return end  -- already decided to skip

    -- Pick start delay and level once on first getup frame
    if wakeup_super_level == 0 then
        wakeup_super_start_delay = math.random(3, 6)
        if math.random(1, 100) > cfg.wakeup_super_chance then
            wakeup_super_level = -1  -- skip this getup
            return
        end
        local gauge = battle.get_super_gauge()
        wakeup_super_level = pick_super_level(gauge, cfg)
        if wakeup_super_level == 0 then return end
        wakeup_super_pressing = false
        wakeup_super_mash_timer = 0
        wakeup_super_mash_target = math.random(2, 4)  -- initial press duration
    end

    -- Wait before starting to mash
    if wakeup_super_getup_frame < wakeup_super_start_delay then return end

    -- Hold only the super's direction (no down-back)
    local facing_right = battle.get_facing()
    local back_key = facing_right and VK.A or VK.D

    if wakeup_super_level == 2 then
        inject_key(back_key)       -- SA2: back + SP+H
    elseif wakeup_super_level == 3 then
        inject_key(VK.S)           -- SA3: down + SP+H
    end
    -- SA1: neutral, no direction

    -- Human-like mashing: random hold (2-5f) then random release (1-3f)
    wakeup_super_mash_timer = wakeup_super_mash_timer + 1
    if wakeup_super_mash_timer >= wakeup_super_mash_target then
        wakeup_super_mash_timer = 0
        wakeup_super_pressing = not wakeup_super_pressing
        if wakeup_super_pressing then
            wakeup_super_mash_target = math.random(2, 5)  -- hold for 2-5 frames
        else
            wakeup_super_mash_target = math.random(1, 3)  -- release for 1-3 frames
        end
    end

    if wakeup_super_pressing then
        inject_key(VK.I)  -- SP
        inject_key(VK.K)  -- Heavy
    else
        -- While "releasing", randomly hold one of the two buttons
        local r = math.random(1, 3)
        if r == 1 then
            inject_key(VK.I)  -- hold SP
        elseif r == 2 then
            inject_key(VK.K)  -- hold Heavy
        end
        -- r == 3: both released
    end
end

---------------------------------------------------------------------------
-- READY state: charge only, no attacks
---------------------------------------------------------------------------
function module.on_ready(cfg, battle)
    prev_injected_vk = {}
    for vk, _ in pairs(injected_vk) do prev_injected_vk[vk] = true end
    release_all()

    -- Hold down-back for charge moves during countdown
    if cfg.move_enabled then
        inject_key(VK.S)
        local facing_right = battle.get_facing()
        local back_key = facing_right and VK.A or VK.D
        inject_key(back_key)

    end
end

---------------------------------------------------------------------------
-- FIGHTING state: full bot behavior
---------------------------------------------------------------------------
function module.on_frame(cfg, battle)
    prev_injected_vk = {}
    for vk, _ in pairs(injected_vk) do prev_injected_vk[vk] = true end
    release_all()

    -- Wakeup super takes over all inputs when active
    local act_st = battle.get_act_st()
    if cfg.wakeup_super_enabled and act_st == ACT_ST_GETUP and wakeup_super_level ~= -1 then
        tick_wakeup_super(cfg, battle)
        return
    end

    tick_pulse(cfg)
    tick_move(cfg, battle)
    tick_wakeup_super(cfg, battle)
    apply_holds(cfg, battle)
end

return module
