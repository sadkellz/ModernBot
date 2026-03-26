local module = {}

module.data = {
    is_training   = false,
    frame         = 0,
    detected_side = nil,
    game_mode     = nil,
    fight_st      = nil,
    wins          = 0,
    losses        = 0,
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
-- Reset (called by state machine on new match)
---------------------------------------------------------------------------
function module.reset()
    module.data.detected_side = nil
    module.data.is_training = false
    module.data.game_mode = nil
    module.data.fight_st = nil
    module.data.frame = 0
    bBattleFlow_instance = nil
    log.debug("[battle] Reset")
end

---------------------------------------------------------------------------
-- Per-frame update (called from main hook)
---------------------------------------------------------------------------
function module.on_frame(cfg)
    module.data.frame = module.data.frame + 1
    if not module.data.detected_side then
        try_detect_side(cfg.player_side)
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

--- Check round result and update win/loss counters.
--- Call once when fight_st transitions to FINISH.
function module.check_round_result()
    local judge = get_gBattle_field("Judge")
    if not judge then return end

    local ok, winner = pcall(judge.call, judge, "get_WinTeam")
    if not ok or winner == nil then return end

    local my_team = (module.data.detected_side or 1) - 1  -- 0-indexed
    if winner == my_team then
        module.data.wins = module.data.wins + 1
        log.debug("[battle] Round won! (" .. module.data.wins .. "W / " .. module.data.losses .. "L)")
    elseif winner >= 0 then
        module.data.losses = module.data.losses + 1
        log.debug("[battle] Round lost. (" .. module.data.wins .. "W / " .. module.data.losses .. "L)")
    end
end

--- Returns the gBattle.Flow object, or nil if not in battle.
function module.get_flow()
    return get_gBattle_field("Flow")
end

--- Returns the gBattle.Game object, or nil.
function module.get_game()
    return get_gBattle_field("Game")
end

--- Returns the captured bBattleFlow instance, or nil.
function module.get_bBattleFlow_instance()
    return bBattleFlow_instance
end

return module
