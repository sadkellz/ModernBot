---------------------------------------------------------------------------
-- Modules
---------------------------------------------------------------------------
local bot_modules = {}
local function safe_require(path)
    local ok, mod_or_err = pcall(require, path)
    if not ok then
        log.debug(string.format("[bot] require('%s') failed: %s", path, tostring(mod_or_err)))
        return nil
    end
    if type(mod_or_err) ~= "table" then
        log.debug(string.format("[bot] module '%s' did not return a table (got %s)", path, type(mod_or_err)))
        return nil
    end
    return mod_or_err
end

do
    local to_load = {
        "modules/battle",
        "modules/ui",
    }
    for _, path in ipairs(to_load) do
        local mod = safe_require(path)
        if mod then
            table.insert(bot_modules, mod)
        end
    end
end

-- Direct references for modules
local battle = bot_modules[1]
local ui = bot_modules[2]

-- VK codes
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

-- Config lives in ui module, main just reads it
local cfg = ui.cfg

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
    end
end

---------------------------------------------------------------------------
-- Continuous holds
---------------------------------------------------------------------------
local function apply_holds()
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
-- Main hook
---------------------------------------------------------------------------
local fbattle = nil

sdk.hook(
    sdk.find_type_definition("app.FBattleInput"):get_method("confirmBattleInput"),
    function(args) fbattle = sdk.to_managed_object(args[2]) end,
    function(retval)
        battle.update(fbattle, cfg.player_side)

        if not cfg.master then release_all() return retval end
        if not battle.data.in_match or not battle.data.detected_side then
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
-- Init UI
---------------------------------------------------------------------------
if ui then
    ui.init({
        battle = battle,
        button_names = BUTTON_NAMES,
    })
end

log.debug("Modern Bot Ready")
