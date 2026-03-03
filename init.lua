-- ia_thermal/init.lua
--
-- if armor.config.fire_protect == true then
--   if core.get_modpath("default") then
--     -- make torches hurt
--     minetest.override_item("default:torch", {damage_per_second = 1})
--     minetest.override_item("default:torch_wall", {damage_per_second = 1})
--     minetest.override_item("default:torch_ceiling", {damage_per_second = 1})
--   end
--
--   -- TODO also expose
--   -- check player damage for any hot nodes we may be protected against
--   minetest.register_on_player_hpchange(function(player, hp_change, reason
--     if reason.type == "node_damage" and reason.node then
--       -- fire protection
--       if armor.config.fire_protect == true and hp_change < 0 then
--         local name = player:get_player_name()
--         for _,igniter in pairs(armor.fire_nodes) do
--           if reason.node == igniter[1] then
--             if armor.def[name].fire >= igniter[2] then
--               hp_change = 0
--             end
--           end
--         end
--       end
--     end
--     return hp_change
--   end, true)
-- end

-- Configuration
local TEMP_MIN_SAFE = 0   -- Degrees Celsius (Freezing)
local TEMP_MAX_SAFE = 45  -- Degrees Celsius (Heatstroke)
local SEA_LEVEL     = 0   -- TODO what about tides ?
local LAPSE_RATE    = 6.5 -- Temp drop per 1000 nodes (Matches Earth's troposphere)
local GEO_GRADIENT  = 15  -- 15°C rise per 1000 nodes (Downward)

ia_thermal          = {}

-- Define the temperature monoid
-- Identity is 0 because we add modifiers to the base biome temperature
ia_thermal.monoid = player_monoids.make_monoid({
    identity = 0,
    combine = function(a, b) return a + b end,
    fold = function(t)
        local sum = 0
        for _, v in pairs(t) do sum = sum + v end
        return sum
    end,
    -- We don't necessarily 'apply' it to a Luanti engine setting,
    -- we use the value in our globalstep logic.
    apply = function(value, player)
        -- Optional: store it in a way other mods can easily read
        -- without calling the monoid API
        player:get_meta():set_float("ia_thermal:modifier", value)
    end,
})

-- Register for thermal influence
ia_thermal.thermal_nodes = {
  ["default:lava_source"] = 5,
  ["default:lava_flowing"] = 5,
  ["default:fire"] = 10,
  ["default:ice"] = -2,
  ["default:snow"] = -1,
  ["default:snowblock"] = -2,
}

-- Helper to allow other mods to register nodes
function ia_thermal.register_thermal_node(nodename, heat_value)
  ia_thermal.thermal_nodes[nodename] = heat_value
end

------ Helper: Check nearby nodes for thermal influence
----local function get_vicinity_modifier(pos) -- TODO expose api function
----    local mod = 0
----    --local radius = 3
----    local radius = 15
----    local minp = vector.subtract(pos, radius)
----    local maxp = vector.add(pos, radius)
----   
----    -- TODO expose these lists of hot & cold items
----    -- TODO expose register/unregister functions for hot & cold items
----
----    -- Find nodes that influence temperature
----    local nodes = minetest.find_nodes_in_area(minp, maxp, {
----        "group:igniter", "default:lava_source", "default:lava_flowing", -- Hot
----        "default:ice", "default:snow", "default:snowblock",            -- Cold
----    })
----
----    for _, npos in ipairs(nodes) do
----        local name = minetest.get_node(npos).name
----        if name:find("lava") or minetest.get_item_group(name, "igniter") > 0 then
----            mod = mod + 5  -- +5°C per hot node (stacks) -- TODO this mod can go in our tables of hot/cold items
----        elseif name:find("ice") or name:find("snow") then
----            mod = mod - 2  -- -2°C per cold node -- TODO
----        end
----    end
------    mod = (mod/100.0) -- NOTE testing
----    mod = (mod/100.0) -- NOTE testing: the temperature effect seems more reasonable when we add this divisor... why? TODO don't hardcode 100.0
----
----    -- Cap vicinity modifier so standing in lava doesn't make you a sun
----    return math.max(-30, math.min(mod, 60)) -- TODO hmm... but what about ia_space? we might be standing in a literal sun. or someplace quite cold. like outer space cold.
----end
---- Updated Vicinity Modifier
--local function get_vicinity_modifier(pos)
--  local mod = 0
--  local radius = 8 -- Reduced radius for performance
--  local minp = vector.subtract(pos, radius)
--  local maxp = vector.add(pos, radius)
--  
--  -- Find nodes from our registry
--  local nodes = minetest.find_nodes_in_area(minp, maxp, "group:igniter")
--  -- Add specific non-group nodes if needed
--  local thermal_list = {}
--  for name, _ in pairs(ia_thermal.thermal_nodes) do
--    table.insert(thermal_list, name)
--  end
--  
--  local found_nodes = minetest.find_nodes_in_area(minp, maxp, thermal_list)
--
--  for _, npos in ipairs(found_nodes) do
--    local name = minetest.get_node(npos).name
--    mod = mod + (ia_thermal.thermal_nodes[name] or 0)
--  end
--  
--  -- Apply the testing divisor you found effective
--  mod = mod / 100.0 -- FIXME probably a function of radius
--  return math.max(-30, math.min(mod, 60))
--end
-- Helper: Check nearby nodes for thermal influence
local function get_vicinity_modifier(pos)
    local mod = 0
    local radius = 8
    local minp = vector.subtract(pos, radius)
    local maxp = vector.add(pos, radius)

    local thermal_list = {}
    for name, _ in pairs(ia_thermal.thermal_nodes) do
        table.insert(thermal_list, name)
    end

    -- Find nodes that influence temperature
    -- We also include "group:igniter" for broad compatibility
    local found_nodes = minetest.find_nodes_in_area(minp, maxp, {"group:igniter"})
    local specific_nodes = minetest.find_nodes_in_area(minp, maxp, thermal_list)

    -- Combine lists (simplified for this iteration)
    local all_found = found_nodes
    for _, p in ipairs(specific_nodes) do table.insert(all_found, p) end

    for _, npos in ipairs(all_found) do
        local node = minetest.get_node(npos)
        local dist = vector.distance(pos, npos)

        -- Inverse distance scaling: closer nodes have more impact
        -- We avoid division by zero by using math.max(1, dist)
        local distance_factor = 1 / math.max(1, dist)

        local node_heat = ia_thermal.thermal_nodes[node.name] or 0
        if node_heat == 0 and minetest.get_item_group(node.name, "igniter") > 0 then
            node_heat = 5 -- Default for unknown igniters
        end

        mod = mod + (node_heat * distance_factor)
    end

    -- The divisor makes the stacking effect of multiple nodes less 'explosive'
    mod = mod / 5.0
    return math.max(-50, math.min(mod, 80))
end

function ia_thermal.get_player_temp(player)
    local pos = player:get_pos()
    local name = player:get_player_name()
    
    -- 1. BASE ENVIRONMENT (Biome + Altitude + Vicinity)
    local heat = minetest.get_biome_data(pos).heat or 50
    local base_temp = (heat * 0.5) - 10

    -- Altitude/Depth scaling
    if pos.y > SEA_LEVEL then
        base_temp = base_temp - ((pos.y - SEA_LEVEL) / 1000 * LAPSE_RATE)
    elseif pos.y < SEA_LEVEL then
        base_temp = base_temp + (math.abs(pos.y) / 1000 * GEO_GRADIENT)
    end

    base_temp = base_temp + get_vicinity_modifier(pos)

    -- 2. FETCH MONOID MODIFIERS
    -- This includes insulation from armor, potions, or special area effects
    local modifier = ia_thermal.monoid:value(player)

    local final_temp = base_temp + modifier

    -- Logging for debug as per your instructions
    minetest.log("action", string.format("[ia_thermal] Player: %s | Base: %.1f | Mod: %.1f | Final: %.1f", 
        name, base_temp, modifier, final_temp))
        
    return final_temp
end

local function handle_phase_changes(pos, temp)
  -- Only act if temperature is extreme
  if temp > 100 then
    -- Melt Ice/Snow nearby
    local nodes = minetest.find_nodes_in_area(
      vector.subtract(pos, 1), vector.add(pos, 1),
      {"group:ice", "group:snow"}
    )
    for _, p in ipairs(nodes) do
      minetest.set_node(p, {name = "default:water_source"})
    end

    -- Ignite combustibles if very hot
    if temp > 200 then
      local air = minetest.find_nodes_in_area(
        vector.subtract(pos, 1), vector.add(pos, 1), {"air"}
      )
      if #air > 0 then
        minetest.set_node(air[1], {name = "fire:basic_flame"})
      end
    end

  elseif temp < -20 then
    -- Freeze Water nearby
    local water = minetest.find_nodes_in_area(
      vector.subtract(pos, 1), vector.add(pos, 1), {"group:water"}
    )
    for _, p in ipairs(water) do
      minetest.set_node(p, {name = "default:ice"})
    end
  end
end

--local function handle_damage_and_movement(playername)
--        -- Reset speed penalty by default (using a unique ID for this mod)
--        player_monoids.speed:del_change(player, "ia_thermal:temp_penalty")
--
--        if t < TEMP_MIN_SAFE then
--            -- 1. Damage Logic
--            local damage = math.ceil((TEMP_MIN_SAFE - t) / 10)
--            player:set_hp(player:get_hp() - damage)
--
--            -- 2. Sluggishness (Built-in Monoid)
--            -- Reduce speed by 10% for every 5 degrees below freezing
--            local penalty = math.max(0.3, 1.0 - (TEMP_MIN_SAFE - t) * 0.02)
--            player_monoids.speed:add_change(player, penalty, "ia_thermal:temp_penalty")
--
--            minetest.chat_send_player(playername, string.format("Warning: Freezing! Speed reduced. (%.1f°C)", t))
--
--        elseif t > TEMP_MAX_SAFE then
--            local damage = math.ceil((t - TEMP_MAX_SAFE) / 10)
--            player:set_hp(player:get_hp() - damage)
--
--	    -- NOTE minimal test server with only {,more_}player_monoids enabled crashes at start ==> more_player_monoids is broken. do not use it
--            -- Use the Saturation Monoid from your library to simulate heat dizziness
--            --if more_player_monoids.saturation then
--            --    more_player_monoids.saturation:add_change(player, 0.5, "ia_thermal:heat_haze")
--            --end
--
--            minetest.chat_send_player(playername, string.format("Warning: Overheating! (%.1f°C)", t))
--        else
--	    -- NOTE minimal test server with only {,more_}player_monoids enabled crashes at start ==> more_player_monoids is broken. do not use it
--            -- Clean up heat effects if safe
--            --if more_player_monoids.saturation then
--            --    more_player_monoids.saturation:del_change(player, "ia_thermal:heat_haze")
--            --end
--        end
--end
--local timer = 0
--minetest.register_globalstep(function(dtime)
--    timer = timer + dtime
--    if timer < 1.0 then return end
--    timer = 0
--
--    for _, player in ipairs(ia_names.get_all_actors()) do
--        local t = ia_thermal.get_player_temp(player)
--        local playername = player:get_player_name()
--	handle_damage_and_movement(playername)
--	handle_phase_changes(player:get_pos(), t) -- TODO what about overlaps? i.e., 2 players are near each other?
--    end
--end)
----minetest.register_globalstep(function(dtime)
----  timer = timer + dtime
----  if timer < 1.0 then return end
----  timer = 0
----
----  for _, player in ipairs(ia_names.get_all_actors()) do
----    -- Ensure player/actor still exists
----    if player:get_pos() then
----      local t = ia_thermal.get_player_temp(player)
----      local name = player:get_player_name()
----
----      -- 1. Damage & Movement Logic
----      player_monoids.speed:del_change(player, "ia_thermal:temp_penalty")
----
----      if t < TEMP_MIN_SAFE then
----        local damage = math.ceil((TEMP_MIN_SAFE - t) / 10)
----        player:set_hp(player:get_hp() - damage)
----        
----        local penalty = math.max(0.3, 1.0 - (TEMP_MIN_SAFE - t) * 0.02)
----        player_monoids.speed:add_change(player, penalty, "ia_thermal:temp_penalty")
----      elseif t > TEMP_MAX_SAFE then
----        local damage = math.ceil((t - TEMP_MAX_SAFE) / 10)
----        player:set_hp(player:get_hp() - damage)
----      end
----
----      -- 2. Environmental Interaction
----      handle_phase_changes(player:get_pos(), t)
----    end
----  end
----end)

-- Refactored helper to prevent scope errors
local function handle_damage_and_movement(player, playername, current_temp)
    -- Safety check for monoid availability
    if not player_monoids or not player_monoids.speed then return end

    -- Reset speed penalty by default using unique ID
    player_monoids.speed:del_change(player, "ia_thermal:temp_penalty")

    if current_temp < TEMP_MIN_SAFE then
        -- Freezing
        local damage = math.ceil((TEMP_MIN_SAFE - current_temp) / 10)
        player:set_hp(player:get_hp() - damage)

        -- Sluggishness
        local penalty = math.max(0.3, 1.0 - (TEMP_MIN_SAFE - current_temp) * 0.02)
        player_monoids.speed:add_change(player, penalty, "ia_thermal:temp_penalty")

        minetest.chat_send_player(playername, string.format("Warning: Freezing! (%.1f°C)", current_temp))

    elseif current_temp > TEMP_MAX_SAFE then
        -- Heatstroke
        local damage = math.ceil((current_temp - TEMP_MAX_SAFE) / 10)
        player:set_hp(player:get_hp() - damage)

        minetest.chat_send_player(playername, string.format("Warning: Overheating! (%.1f°C)", current_temp))
    end
end

local timer = 0
minetest.register_globalstep(function(dtime)
    timer = timer + dtime
    if timer < 1.0 then return end
    timer = 0

    -- Use actor list from ia_names
    local actors = ia_names.get_all_actors()

    for _, player in ipairs(actors) do
        -- Explicit assertion of object validity
        if player and player:get_pos() then
            local t = ia_thermal.get_player_temp(player)
            local playername = player:get_player_name()

            -- Pass variables explicitly to avoid nil references
            handle_damage_and_movement(player, playername, t)
            handle_phase_changes(player:get_pos(), t)
        end
    end
end)



-- TODO in ia_phase_change ???
-- TODO freeze liquids
-- TODO melt solids
-- TODO phase changes, basically
-- TODO ignite combustibles
