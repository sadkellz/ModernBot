---------------------------------------------------------------------------
-- Module loader
---------------------------------------------------------------------------
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

local config = safe_require("modules/config")
local battle = safe_require("modules/battle")
local input  = safe_require("modules/input")
local menu   = safe_require("modules/menu")
local ui     = safe_require("modules/ui")

local cfg = config and config.cfg

---------------------------------------------------------------------------
-- State machine
---------------------------------------------------------------------------
local FIGHT_ST_NAMES = {
    [0] = "STAGE_INIT", [1] = "ROUND_INIT", [2] = "APPEAR", [3] = "READY",
    [4] = "NOW", [5] = "FINISH", [6] = "WIN_WAIT", [7] = "WIN", [8] = "NUM",
}

local state = { current = "idle" }
local prev_fight_st = nil
local state_log_timer = 0

local function set_state(new)
    if new == state.current then return end
    log.debug(string.format("[state] %s -> %s", state.current, new))

    -- Reset battle data when entering a new match
    if new == "loading" and (state.current == "idle" or state.current == "result" or state.current == "round_end") then
        battle.reset()
    end

    if new == "round_end" then
        round_end_frames = 0
    end

    state.current = new
end

---------------------------------------------------------------------------
-- Per-state behavior
---------------------------------------------------------------------------
local function do_idle()
    input.release_all()
end

local function do_loading()
    input.release_all()
    battle.on_frame(cfg)
    -- Skip intro (APPEAR = fight_st 2)
    if cfg.master and cfg.auto_skip and battle.data.fight_st == 2 then
        input.inject_key(input.VK.ESCAPE)
    end
end

local function do_ready()
    battle.on_frame(cfg)
    if not cfg.master
        or (battle.data.is_training and not cfg.allow_training)
        or not battle.data.detected_side
    then
        input.release_all()
        return
    end
    input.on_ready(cfg, battle)
end

local function do_fighting()
    battle.on_frame(cfg)
    if not cfg.master
        or (battle.data.is_training and not cfg.allow_training)
        or not battle.data.detected_side
    then
        input.release_all()
        return
    end
    input.on_frame(cfg, battle)
end

local round_end_frames = 0

local function do_round_end()
    input.release_all()
    round_end_frames = round_end_frames + 1
    -- Skip win pose (WIN_WAIT=6, WIN=7) — toggle ESC to generate fresh trigger
    if cfg.master and cfg.auto_skip and battle.data.fight_st and battle.data.fight_st >= 6 then
        if round_end_frames % 2 == 1 then
            input.inject_key(input.VK.ESCAPE)
        end
    end
end

local function do_result()
    -- Menu module handles this state via its own on_frame
end

---------------------------------------------------------------------------
-- State transitions (driven by fight_st from gBattle.Game)
---------------------------------------------------------------------------
local function update_state()
    local game = battle.get_game()

    if not game then
        -- No game object: go idle
        if prev_fight_st ~= nil then
            log.debug("[state] fight_st: " .. (FIGHT_ST_NAMES[prev_fight_st] or tostring(prev_fight_st)) .. " -> nil (no game)")
            prev_fight_st = nil
        end
        if state.current ~= "result" then
            set_state("idle")
        end
        return
    end

    local ok, st = pcall(game.call, game, "get_FightST")
    if not ok or not st then return end

    -- Log fight_st transitions
    if st ~= prev_fight_st then
        log.debug(string.format("[state] fight_st: %s -> %s",
            FIGHT_ST_NAMES[prev_fight_st] or tostring(prev_fight_st),
            FIGHT_ST_NAMES[st] or tostring(st)))
        prev_fight_st = st
    end

    -- Update battle data
    battle.data.fight_st = st

    -- Transitions
    if state.current == "idle" then
        if st >= 0 and st <= 2 then set_state("loading")
        elseif st == 3 then set_state("ready")
        elseif st == 4 then set_state("fighting")
        end

    elseif state.current == "loading" then
        if st == 3 then set_state("ready")
        elseif st == 4 then set_state("fighting")
        elseif st >= 5 then set_state("round_end")
        end

    elseif state.current == "ready" then
        if st == 4 then set_state("fighting")
        elseif st >= 5 then set_state("round_end")
        elseif st <= 2 then set_state("loading")
        end

    elseif state.current == "fighting" then
        if st >= 5 then set_state("round_end")
        elseif st <= 2 then set_state("loading")
        elseif st == 3 then set_state("ready")
        end

    elseif state.current == "round_end" then
        if st >= 0 and st <= 2 then set_state("loading")
        elseif st == 3 then set_state("ready")
        elseif st == 4 then set_state("fighting")
        end
        -- result transition handled by menu module hook

    elseif state.current == "result" then
        if st >= 0 and st <= 2 then set_state("loading")
        elseif st == 3 then set_state("ready")
        elseif st == 4 then set_state("fighting")
        end
    end
end

---------------------------------------------------------------------------
-- Main battle hook (runs at game tick rate, not render rate)
---------------------------------------------------------------------------
sdk.hook(
    sdk.find_type_definition("app.FBattleInput"):get_method("confirmBattleInput"),
    function(args) end,
    function(retval)
        if state.current == "fighting" then
            do_fighting()
        elseif state.current == "ready" then
            do_ready()
        elseif state.current == "loading" then
            do_loading()
        end
        return retval
    end
)

---------------------------------------------------------------------------
-- Frame update: transitions + state behavior
---------------------------------------------------------------------------
re.on_frame(function()
    update_state()

    -- Run per-state behavior for non-hook states
    if state.current == "idle" then
        do_idle()
    elseif state.current == "round_end" then
        do_round_end()
    elseif state.current == "result" then
        do_result()
    end

    -- Periodic state dump
    state_log_timer = state_log_timer + 1
    if cfg.debug_log and state_log_timer >= 60 then
        state_log_timer = 0
        local side = battle.data.detected_side
        local facing = battle.get_facing()
        local facing_str = facing == true and "right" or facing == false and "left" or "?"
        local menu_state = menu and menu.data.state or "n/a"
        log.debug("[state] --- Periodic ---")
        log.debug("[state]   bot:       " .. state.current)
        log.debug("[state]   fight_st:  " .. (FIGHT_ST_NAMES[battle.data.fight_st] or tostring(battle.data.fight_st)))
        log.debug("[state]   side:      P" .. (side or "?"))
        log.debug("[state]   facing:    " .. facing_str)
        log.debug("[state]   menu:      " .. menu_state)
        log.debug("[state]   training:  " .. tostring(battle.data.is_training))
    end
end)

---------------------------------------------------------------------------
-- Init modules
---------------------------------------------------------------------------
if menu then
    menu.init({
        cfg = cfg,
        battle = battle,
        input = input,
        state = state,
        set_state = set_state,
    })
end

if ui then
    ui.init({
        cfg = cfg,
        config = config,
        battle = battle,
        menu = menu,
        state = state,
        button_names = input.BUTTON_NAMES,
    })
end

log.debug("Modern Bot Ready")
