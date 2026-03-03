-- Configuration
local TEMP_MIN_SAFE = 0   -- Degrees Celsius (Freezing)
local TEMP_MAX_SAFE = 45  -- Degrees Celsius (Heatstroke)
local SEA_LEVEL = 0
local LAPSE_RATE = 6.5    -- Temp drop per 1000 nodes (Matches Earth's troposphere)

local thermal = {}

-- Configuration
local TEMP_MIN_SAFE = 0    -- 0°C
local TEMP_MAX_SAFE = 45   -- 45°C
local SEA_LEVEL = 0
local LAPSE_RATE = 6.5     -- 6.5°C drop per 1000 nodes (Upward)
local GEO_GRADIENT = 15    -- 15°C rise per 1000 nodes (Downward)

-- Helper: Check nearby nodes for thermal influence
local function get_vicinity_modifier(pos) -- TODO expose api function
    local mod = 0
    --local radius = 3
    local radius = 15
    local minp = vector.subtract(pos, radius)
    local maxp = vector.add(pos, radius)
   
    -- TODO expose these lists of hot & cold items
    -- TODO expose register/unregister functions for hot & cold items

    -- Find nodes that influence temperature
    local nodes = minetest.find_nodes_in_area(minp, maxp, {
        "group:igniter", "default:lava_source", "default:lava_flowing", -- Hot
        "default:ice", "default:snow", "default:snowblock",            -- Cold
    })

    for _, npos in ipairs(nodes) do
        local name = minetest.get_node(npos).name
        if name:find("lava") or minetest.get_item_group(name, "igniter") > 0 then
            mod = mod + 5  -- +5°C per hot node (stacks) -- TODO this mod can go in our tables of hot/cold items
        elseif name:find("ice") or name:find("snow") then
            mod = mod - 2  -- -2°C per cold node -- TODO
        end
    end
   
--    mod = (mod/100.0) -- NOTE testing
    mod = (mod/100.0) -- NOTE testing: the temperature effect seems more reasonable when we add this divisor... why? TODO don't hardcode 100.0

    -- Cap vicinity modifier so standing in lava doesn't make you a sun
    return math.max(-30, math.min(mod, 60)) -- TODO hmm... but what about ia_space? we might be standing in a literal sun. or someplace quite cold. like outer space cold.
end
--function thermal.get_player_temp(player)
--    local pos = player:get_pos()
--
--    -- 1. BIOME BASE
--    local heat = minetest.get_biome_data(pos).heat or 50
--    local current_temp = (heat * 0.5) - 10
--
--    -- 2. ALTITUDE & DEPTH SCALING
--    if pos.y > SEA_LEVEL then
--        -- Cooling effect as we climb the Axis
--        current_temp = current_temp - ((pos.y - SEA_LEVEL) / 1000 * LAPSE_RATE)
--    elseif pos.y < SEA_LEVEL then
--        -- Heating effect as we dig toward the core
--        -- math.abs turns the negative Y into a positive distance for the multiplier
--        current_temp = current_temp + (math.abs(pos.y) / 1000 * GEO_GRADIENT)
--    end
--
--    -- 3. VICINITY (Lava/Ice/Torches)
--    current_temp = current_temp + get_vicinity_modifier(pos)
--
--    -- 4. INSULATION (Armor)
--    local _, armor_groups = armor and armor:get_valid_player_armor(player) or nil, {}
--    local fleshy_armor = armor_groups.fleshy or 0
--
--    -- Cold Insulation: Armor keeps you warm
--    if current_temp < TEMP_MIN_SAFE then
--        current_temp = current_temp + (fleshy_armor * 0.2)
--    -- Heat Protection: If the armor has a 'fire' group, it helps with heat
--    elseif current_temp > TEMP_MAX_SAFE then
--        local fire_prot = armor_groups.fire or 0
--        current_temp = current_temp - (fire_prot * 0.5)
--    end
--
--    return current_temp
--end
function thermal.get_player_temp(player)
    local pos = player:get_pos()
    
    -- 1. BIOME BASE (-10 to 40C)
    local heat = minetest.get_biome_data(pos).heat or 50
    local current_temp = (heat * 0.5) - 10

    -- 2. ALTITUDE & DEPTH
    if pos.y > SEA_LEVEL then
        current_temp = current_temp - ((pos.y - SEA_LEVEL) / 1000 * LAPSE_RATE)
    elseif pos.y < SEA_LEVEL then
        current_temp = current_temp + (math.abs(pos.y) / 1000 * GEO_GRADIENT)
    end

    -- 3. VICINITY
    current_temp = current_temp + get_vicinity_modifier(pos)

    -- 4. INSULATION (The Fix)
    -- Instead of get_valid_player_armor, we fetch the groups directly 
    -- from the armor mod's tracked table for that player.
    local name = player:get_player_name()
    local armor_groups = armor.def[name] and armor.def[name].groups or {}
    
    local fleshy_armor = armor_groups.fleshy or 0
    local fire_prot = armor_groups.fire or 0

    -- Cold Insulation
    if current_temp < TEMP_MIN_SAFE then
        current_temp = current_temp + (fleshy_armor * 0.2)
    -- Heat Protection
    elseif current_temp > TEMP_MAX_SAFE then
        current_temp = current_temp - (fire_prot * 0.5)
    end

    minetest.log('temperature: '..current_temp)
    return current_temp
end


--function thermal.get_player_temp(player)
--    local pos = player:get_pos()
--    
--    -- 1. BIOME BASE
--    -- Minetest heat ranges 0-100. We map this to -10°C to 40°C
--    local heat = minetest.get_biome_data(pos).heat or 50
--    local current_temp = (heat * 0.5) - 10
--
--    -- 2. ALTITUDE LAPSE
--    -- Drops temperature as you climb toward the World Axis
--    if pos.y > SEA_LEVEL then
--        current_temp = current_temp - ((pos.y - SEA_LEVEL) / 1000 * LAPSE_RATE)
--    end
--
--    -- 3. VICINITY (Lava/Ice/Torches)
--    current_temp = current_temp + get_vicinity_modifier(pos)
--
--    -- 4. INSULATION (Armor)
--    -- We assume '3d_armor' or similar. 
--    -- Every 10 points of armor 'fleshy' group acts as 2°C of protection against cold
--    local _, armor_groups = armor and armor:get_valid_player_armor(player) or nil, {}
--    local armor_val = armor_groups.fleshy or 0
--    
--    if current_temp < TEMP_MIN_SAFE then
--        current_temp = current_temp + (armor_val * 0.2)
--    end
--
--    return current_temp
--end

-- Main Loop
--minetest.register_globalstep(function(dtime)
--    for _, player in ipairs(minetest.get_connected_players()) do
--        -- Throttled to once per second
--        --if math.floor(minetest.get_gametime()) % 1 == 0 then
--        if math.floor(minetest.get_gametime()) % 10 == 0 then -- FIXME
--            local t = thermal.get_player_temp(player)
--            local name = player:get_player_name()
--
--            if t < TEMP_MIN_SAFE then
--                -- Freezing Logic
--                --local damage = math.ceil((TEMP_MIN_SAFE - t) / 10)
--                local damage = math.ceil((TEMP_MIN_SAFE - t) / 100) -- NOTE testing
--                player:set_hp(player:get_hp() - damage)
--                minetest.chat_send_player(name, string.format("Warning: Extreme Cold (%.1f°C)", t))
--            elseif t > TEMP_MAX_SAFE then
--                -- Overheating Logic
--                --player:set_hp(player:get_hp() - 1)
--                --lminetest.chat_send_player(name, string.format("Warning: Overheating (%.1f°C)", t))
--                local damage = math.floor((t - TEMP_MAX_SAFE) / 100) -- NOTE testing
--                player:set_hp(player:get_hp() - damage)
--                minetest.chat_send_player(name, string.format("Warning: Overheating (%.1f°C)", t))
--            end
--        end
--    end
--end)
local timer = 0
minetest.register_globalstep(function(dtime)
    timer = timer + dtime
    -- Set your interval here (e.g., 2.0 seconds for balance)
    if timer < 1.0 then return end
    timer = 0 -- Reset for the next cycle

    --for _, player in ipairs(minetest.get_connected_players()) do
    for _, player in ipairs(fakelib.get_all_actors()) do
        local t = thermal.get_player_temp(player)
        local name = player:get_player_name()

        -- Restore your original damage logic now that it only hits once
        if t < TEMP_MIN_SAFE then
            local damage = math.ceil((TEMP_MIN_SAFE - t) / 10)
            player:set_hp(player:get_hp() - damage)
            minetest.chat_send_player(name, string.format("Warning: Extreme Cold (%.1f°C)", t))
        
        elseif t > TEMP_MAX_SAFE then
            local damage = math.ceil((t - TEMP_MAX_SAFE) / 10)
            player:set_hp(player:get_hp() - damage)
            minetest.chat_send_player(name, string.format("Warning: Overheating (%.1f°C)", t))
        end
    end
end)
