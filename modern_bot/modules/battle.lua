local module = {}

module.data = {
    in_match      = false,
    is_fighting   = false,
    is_training   = false,
    frame         = 0,
    detected_side = nil,
    game_mode     = nil,
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
local TRAINING_MODES = {
    [0] = false, -- NONE
}

local function read_game_mode()
    local setting = get_gBattle_field("Setting")
    if not setting then return nil, false end
    local ok_m, mode = pcall(setting.get_field, setting, "GameMode")
    local ok_o, online = pcall(setting.get_field, setting, "IsOnline")
    if ok_m then
        module.data.game_mode = mode
    end
    return (ok_m and mode or nil), (ok_o and online or false)
end

local function is_training_mode(mode)
    if mode == nil then return false end
    -- Check by name: TRAINING, ONLINE_TRAINING, STORY_TRAINING, TUTORIAL, etc.
    -- Training modes are always P1
    local training_modes = {
        -- These enum values need to be checked at runtime
    }
    -- Use string check on the GameMode field name
    local setting = get_gBattle_field("Setting")
    if not setting then return false end
    local ok, mode_val = pcall(setting.get_field, setting, "GameMode")
    if not ok then return false end
    -- GameMode is a byte enum; we check the type name via REFramework
    local mode_type = sdk.find_type_definition("app.EGameMode")
    if not mode_type then return false end
    -- Try known training mode check: gBattle.Training is non-nil in training
    local training = get_gBattle_field("Training")
    return training ~= nil
end

local function try_detect_side_online()
    log.debug("[battle] try_detect_side_online: bBattleFlow_instance=" .. tostring(bBattleFlow_instance))
    if not bBattleFlow_instance then
        return nil
    end

    -- Access m_session field
    local ok_s, session = pcall(bBattleFlow_instance.get_field, bBattleFlow_instance, "m_session")
    log.debug("[battle] m_session: ok=" .. tostring(ok_s) .. " val=" .. tostring(session))
    if not ok_s or not session then return nil end

    -- Access SelfBattleMemberInfo property
    local ok_m, member_info = pcall(session.call, session, "get_SelfBattleMemberInfo")
    log.debug("[battle] SelfBattleMemberInfo: ok=" .. tostring(ok_m) .. " val=" .. tostring(member_info))
    if not ok_m or not member_info then return nil end

    -- Read MemberIndex field
    local ok_i, idx = pcall(member_info.get_field, member_info, "MemberIndex")
    log.debug("[battle] MemberIndex: ok=" .. tostring(ok_i) .. " val=" .. tostring(idx))
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
    log.debug(string.format("[battle] GameMode=%s IsOnline=%s", tostring(mode), tostring(online)))

    -- Training/local modes: always P1
    if not online then
        module.data.detected_side = 1
        module.data.is_training = is_training_mode(mode)
        log.debug("[battle] Local mode, defaulting to P1 (training=" .. tostring(module.data.is_training) .. ")")
        return
    end

    -- Online: use bBattleFlow session data
    local side = try_detect_side_online()
    if side ~= nil then
        module.data.detected_side = side + 1  -- 0-indexed -> 1-indexed
        log.debug("[battle] Detected online side: P" .. module.data.detected_side)
    else
        log.debug("[battle] Online side detection failed, will retry")
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
end

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
    if now ~= module.data.in_match then
        module.data.in_match = now
        module.data.frame = 0
        reset()
    end

    -- Check if actively fighting (round timer ticking)
    if module.data.in_match then
        local round = get_gBattle_field("Round")
        if round then
            local ok2, active = pcall(round.call, round, "TimerWorking")
            module.data.is_fighting = ok2 and active or false
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
        log.debug(string.format("[battle] P%s facing_%s f%d training=%s",
            side or "?", facing_str, module.data.frame,
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

return module
