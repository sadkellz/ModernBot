local module = {}

---------------------------------------------------------------------------
-- VK codes & button definitions
---------------------------------------------------------------------------
local VK = {
    W = 87, A = 65, S = 83, D = 68,
    U = 85, I = 73, O = 79,
    J = 74, K = 75, L = 76,
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

module.release_all = release_all

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
local move_charge_timer = 0   -- total frames spent holding down
local move_ready_timer = 0    -- frames actionable after charge_min met
local move_jump_timer = 0
local move_delay_target = 0
local move_current_buttons = nil
local move_jump_dir = nil  -- nil=neutral, VK.A=left, VK.D=right

local MOVE_OPTIONS = {
    { BUTTONS[1].vk },                    -- Light
    { BUTTONS[2].vk },                    -- Medium
    { BUTTONS[3].vk },                    -- Heavy
    { BUTTONS[2].vk, BUTTONS[3].vk },     -- Medium + Heavy
}

local JUMP_DIRS = { nil, VK.A, VK.D }  -- neutral, left, right

local ACTIONABLE_STATES = {
    [1] = true,   -- STAND
    [3] = true,   -- SIT
    [5] = true,   -- SITD
    [6] = true,   -- WALK
    [7] = true,   -- DUCK_WALK
    [8] = true,   -- FOOTWORK
}

local function tick_move(cfg, battle)
    if not cfg.move_enabled then
        move_phase = MOVE_PHASE_CHARGE
        move_charge_timer = 0
        move_ready_timer = 0
        move_jump_timer = 0
        move_delay_target = 0
        move_current_buttons = nil
        move_jump_dir = nil
        return
    end

    if move_phase == MOVE_PHASE_CHARGE then
        -- Always hold down while charging
        inject_key(VK.S)
        move_charge_timer = move_charge_timer + 1

        -- Check if actionable AND charged enough
        local act_st = battle.get_act_st()
        if act_st and ACTIONABLE_STATES[act_st] and move_charge_timer >= cfg.move_charge_min then
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
            end
        elseif not (act_st and ACTIONABLE_STATES[act_st]) then
            -- Not actionable: reset ready timer but keep charge timer
            move_ready_timer = 0
            move_delay_target = 0
        end

    elseif move_phase == MOVE_PHASE_JUMP then
        -- Jump + attack + random direction
        move_jump_timer = move_jump_timer + 1
        inject_key(VK.W)
        if move_jump_dir == VK.A then inject_key(VK.A)
        elseif move_jump_dir == VK.D then inject_key(VK.D)
        end
        for _, vk in ipairs(move_current_buttons) do
            inject_key(vk)
        end

        if move_jump_timer >= cfg.move_jump_frames then
            -- Back to charging
            move_phase = MOVE_PHASE_CHARGE
            move_charge_timer = 0
            move_ready_timer = 0
            move_delay_target = 0
            move_current_buttons = nil
            move_jump_dir = nil
        end
    end
end

---------------------------------------------------------------------------
-- Per-frame update (called from main hook when in match)
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
