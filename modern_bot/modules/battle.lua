local module = {}

module.data = {
    in_match      = false,
    is_fighting   = false,
    is_training   = false,
    frame         = 0,
    detected_side = nil,
    game_mode     = nil,
    fight_st      = nil,
}

---------------------------------------------------------------------------
-- gBattle access
---------------------------------------------------------------------------
local gBattle = sdk.find_type_definition("gBattle")

local function get_gBattle_field(name)
    if not gBattle then return nil end
    local field = gBattle:get_field(name)
    if not field then return nil end
    return field:get_data()
end

local function get_player(id)
    local sPlayer = get_gBattle_field("Player")
    if not sPlayer then return nil end
    local ok, p = pcall(sPlayer.call, sPlayer, "getPlayer", id)
    return ok and p or nil
end

---------------------------------------------------------------------------
-- bBattleFlow capture (for online side detection)
---------------------------------------------------------------------------
local bBattleFlow_instance = nil

local bf_type = sdk.find_type_definition("app.battle.bBattleFlow")
if bf_type then
    local update_method = bf_type:get_method("updateFrame")
    if update_method then
        sdk.hook(update_method,
            function(args)
                bBattleFlow_instance = sdk.to_managed_object(args[2])
            end,
            function(retval) return retval end
        )
    end
end

---------------------------------------------------------------------------
-- Side detection
---------------------------------------------------------------------------
local function read_game_mode()
    local setting = get_gBattle_field("Setting")
    if not setting then return nil, false end
    local ok_m, mode = pcall(setting.get_field, setting, "GameMode")
    local ok_o, online = pcall(setting.get_field, setting, "IsOnline")
    if ok_m then module.data.game_mode = mode end
    return (ok_m and mode or nil), (ok_o and online or false)
end

-- EGameMode enum values (from il2cpp dump)
local EGAMEMODE = {
    TRAINING         = 2,
    ONLINE_TRAINING  = 18,
    STORY_TRAINING   = 10,
}

local TRAINING_MODES = {
    [EGAMEMODE.TRAINING]        = true,
    [EGAMEMODE.ONLINE_TRAINING] = true,
    [EGAMEMODE.STORY_TRAINING]  = true,
}

local function is_training_mode()
    return TRAINING_MODES[module.data.game_mode] or false
end

local function try_detect_side_online()
    if not bBattleFlow_instance then return nil end

    local ok_s, session = pcall(bBattleFlow_instance.get_field, bBattleFlow_instance, "m_session")
    if not ok_s or not session then return nil end

    local ok_m, member_info = pcall(session.call, session, "get_SelfBattleMemberInfo")
    if not ok_m or not member_info then return nil end

    local ok_i, idx = pcall(member_info.get_field, member_info, "MemberIndex")
    if not ok_i then return nil end

    return idx  -- 0 = P1 side, 1 = P2 side
end

local function try_detect_side(player_side_cfg)
    -- Manual override: 0=Auto, 1=P1, 2=P2
    if player_side_cfg and player_side_cfg > 0 then
        module.data.detected_side = player_side_cfg
        log.debug("[battle] Side set manually: P" .. module.data.detected_side)
        return
    end

    local mode, online = read_game_mode()
    module.data.game_mode = mode

    -- Training/local modes: always P1
    if not online then
        module.data.detected_side = 1
        module.data.is_training = is_training_mode()
        log.debug(string.format("[battle] Side=P1 (local, mode=%s, training=%s)",
            tostring(mode), tostring(module.data.is_training)))
        return
    end

    -- Online: use bBattleFlow session data
    local side = try_detect_side_online()
    if side ~= nil then
        module.data.detected_side = side + 1  -- 0-indexed -> 1-indexed
        log.debug("[battle] Side=P" .. module.data.detected_side .. " (online)")
    end
end

---------------------------------------------------------------------------
-- Match state
---------------------------------------------------------------------------
local function reset()
    module.data.detected_side = nil
    module.data.is_fighting = false
    module.data.is_training = false
    module.data.game_mode = nil
    module.data.fight_st = nil
    bBattleFlow_instance = nil
end

-- Periodic check for match exit (confirmBattleInput stops firing outside matches)
re.on_frame(function()
    if not module.data.in_match then return end
    local flow = get_gBattle_field("Flow")
    if not flow then
        module.data.in_match = false
        module.data.is_fighting = false
        module.data.fight_st = nil
        return
    end
    local ok, ended = pcall(flow.call, flow, "IsBattleEnd")
    if ok and ended then
        module.data.in_match = false
        module.data.is_fighting = false
        module.data.fight_st = nil
    end
end)

local function update_match_state()
    local flow = get_gBattle_field("Flow")
    if not flow then
        if module.data.in_match then
            module.data.in_match = false
            reset()
        end
        return false
    end

    local ok, ended = pcall(flow.call, flow, "IsBattleEnd")
    local now = ok and not ended
    if now and not module.data.in_match then
        -- Entering match
        module.data.in_match = true
        module.data.frame = 0
    elseif not now and module.data.in_match then
        -- Leaving match (don't reset detected_side here, STAGE_INIT handles that)
        module.data.in_match = false
        module.data.is_fighting = false
        module.data.fight_st = nil
    end

    -- Check fight phase
    if module.data.in_match then
        local game = get_gBattle_field("Game")
        if game then
            local ok2, st = pcall(game.call, game, "get_FightST")
            local prev_st = module.data.fight_st
            module.data.fight_st = ok2 and st or nil
            module.data.is_fighting = ok2 and st == 4 or false  -- FIGHT_ST.NOW = 4

            -- New match detected (STAGE_INIT): re-detect side
            if ok2 and st == 0 and prev_st ~= 0 then
                module.data.detected_side = nil
                module.data.is_training = false
                module.data.game_mode = nil
                bBattleFlow_instance = nil
                log.debug("[battle] New match detected (STAGE_INIT), resetting side")
            end
        end
    end

    return module.data.in_match
end

---------------------------------------------------------------------------
-- Per-frame update
---------------------------------------------------------------------------
function module.on_frame(cfg)
    if not update_match_state() then return end
    module.data.frame = module.data.frame + 1
    if not module.data.detected_side then
        try_detect_side(cfg.player_side)
    end

    -- Log side and facing once per second
    if cfg.debug_log and module.data.frame % 60 == 1 then
        local side = module.data.detected_side
        local facing = module.get_facing()
        local facing_str = facing == true and "right" or facing == false and "left" or "?"
        local act = module.get_act_st_name()
        log.debug(string.format("[battle] P%s facing_%s act=%s f%d fighting=%s training=%s",
            side or "?", facing_str, act, module.data.frame,
            tostring(module.data.is_fighting),
            tostring(module.data.is_training)))
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function module.get_my_index()
    return module.data.detected_side or 1
end

--- Returns true if our character is facing right, false if facing left, nil if unknown.
function module.get_facing()
    local idx = module.get_my_index()
    local p = get_player(idx - 1)  -- getPlayer is 0-indexed
    if not p then return nil end
    local ok, rl_dir = pcall(p.get_field, p, "rl_dir")
    if not ok then return nil end
    return rl_dir
end

--- ACT_ST.ID enum names for logging
local ACT_ST_NAMES = {
    [0] = "NONE", "STAND", "STAND_TURN", "SIT", "SIT_TURN", "SITD",
    "WALK", "DUCK_WALK", "FOOTWORK", "DASH", "KDASH",
    "JUMP", "JUMP_NORM", "JUMP_RET", "JUMP_LAND",
    "SJUMP", "SJUMP_NORM", "SJUMP_RET", "SJUMP_DMG",
    "WJUMP", "WSJUMP", "TJUMP",
    "ATCK", "ATCK_LAND", "DEF", "JDEF", "PARRY",
    "CATCH", "NOKI", "NIJI", "HOLD",
    "DAMAGE", "FALL", "GETUP", "UKEMI", "SLEEP",
    "FLYING", "SPECIAL", "SUPER", "TOUCH", "WITHDRAW", "WIN",
}

--- Returns the act_st value for our player, or nil.
function module.get_act_st()
    local idx = module.get_my_index()
    local p = get_player(idx - 1)
    if not p then return nil end
    local ok, st = pcall(p.get_field, p, "act_st")
    return ok and st or nil
end

--- Returns the act_st name string, or "?" if unknown.
function module.get_act_st_name()
    local st = module.get_act_st()
    if st == nil then return "?" end
    return ACT_ST_NAMES[st] or tostring(st)
end

--- Returns the gBattle.Flow object, or nil if not in battle.
function module.get_flow()
    return get_gBattle_field("Flow")
end

--- Returns the gBattle.Game object, or nil.
function module.get_game()
    return get_gBattle_field("Game")
end

return module
