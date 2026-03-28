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

local function tick_pulse(cfg)
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

    tick_pulse(cfg)
    tick_move(cfg, battle)
    apply_holds(cfg, battle)
end

return module
