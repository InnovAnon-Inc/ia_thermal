-- ia_thermal/init.lua
-- Handles thermal environment logic, now integrated with tidesandfloods.

assert(minetest.get_modpath('ia_util'))
assert(ia_util ~= nil)
local modname                    = minetest.get_current_modname() or "ia_thermal"
local storage                    = minetest.get_mod_storage()
ia_thermal                       = {}
local modpath, S                 = ia_util.loadmod(modname)
local log                        = ia_util.get_logger(modname)
local assert                     = ia_util.get_assert(modname)

-- Configuration
local TEMP_MIN_SAFE = 0
local TEMP_MAX_SAFE = 45
local LAPSE_RATE    = 6.5
local GEO_GRADIENT  = 15

-- Helper: Get the current effective sea level from tidesandfloods
local function get_current_sea_level()
    -- Integration: Use the modern tidesandfloods global
    if tidesandfloods and tidesandfloods.sealevel then
        return tidesandfloods.sealevel
    end
    
    -- Fallback to mapgen default if mod is missing or uninitialized
    return tonumber(minetest.get_mapgen_setting("water_level")) or 1
end

-- Temperature Calculation
function ia_thermal.get_player_temp(player)
    local pos = player:get_pos()
    if not pos then return 20 end -- Safety fallback
    
    -- 1. BASE ENVIRONMENT
    local heat = minetest.get_biome_data(pos).heat or 50
    local base_temp = (heat * 0.5) - 10

    -- Dynamic Sea Level from tidesandfloods
    local current_sea_level = get_current_sea_level()

    -- Altitude/Depth scaling relative to dynamic tide
    -- This ensures that as the tide rises, the "freezing" mountain peak effect moves with it
    if pos.y > current_sea_level then
        base_temp = base_temp - ((pos.y - current_sea_level) / 1000 * LAPSE_RATE)
    elseif pos.y < current_sea_level then
        -- Pressure/Geothermal scaling
        base_temp = base_temp + (math.abs(pos.y - current_sea_level) / 1000 * GEO_GRADIENT)
    end

    -- 2. Water Submersion Check
    -- Tidesandfloods changes which nodes are at foot-level.
    -- Water has significantly higher thermal conductivity than air.
    local node = minetest.get_node(pos)
    local def = minetest.registered_nodes[node.name] or {}
    
    -- Check if the player is currently in water (source, flowing, or tides:wave)
    if minetest.get_item_group(node.name, "water") > 0 or node.name == "tides:wave" then
        -- Rapidly pull player temp toward water temp (equilibrium)
        base_temp = (base_temp + 15) / 2
    end

    -- 3. Vicinity & Monoids
    base_temp = base_temp + ia_thermal.get_vicinity_modifier(pos)
    local modifier = ia_thermal.monoid:value(player)
    local final_temp = base_temp + modifier

    return final_temp
end

-- Define the temperature monoid
ia_thermal.monoid = player_monoids.make_monoid({
    identity = 0,
    combine = function(a, b) return a + b end,
    fold = function(t)
        local sum = 0
        for _, v in pairs(t) do sum = sum + v end
        return sum
    end,
    apply = function(value, player)
        player:get_meta():set_float("ia_thermal:modifier", value)
    end,
})

-- Thermal Node Registry
ia_thermal.thermal_nodes = {
    ["default:lava_source"] = 5,
    ["default:lava_flowing"] = 5,
    ["default:fire"] = 10,
    ["default:ice"] = -2,
    ["default:snow"] = -1,
    ["default:snowblock"] = -2,
}

function ia_thermal.register_thermal_node(nodename, heat_value)
    ia_thermal.thermal_nodes[nodename] = heat_value
end

-- Vicinity Modifier with Distance Scaling
function ia_thermal.get_vicinity_modifier(pos)
    local mod = 0
    local radius = 8
    local minp = vector.subtract(pos, radius)
    local maxp = vector.add(pos, radius)

    local thermal_list = {}
    for name, _ in pairs(ia_thermal.thermal_nodes) do
        table.insert(thermal_list, name)
    end

    local found_nodes = minetest.find_nodes_in_area(minp, maxp, {"group:igniter"})
    local specific_nodes = minetest.find_nodes_in_area(minp, maxp, thermal_list)

    local all_found = found_nodes
    for _, p in ipairs(specific_nodes) do table.insert(all_found, p) end

    for _, npos in ipairs(all_found) do
        local node = minetest.get_node(npos)
        local dist = vector.distance(pos, npos)
        local distance_factor = 1 / math.max(1, dist)

        local node_heat = ia_thermal.thermal_nodes[node.name] or 0
        if node_heat == 0 and minetest.get_item_group(node.name, "igniter") > 0 then
            node_heat = 5
        end

        mod = mod + (node_heat * distance_factor)
    end

    mod = mod / 5.0
    return math.max(-50, math.min(mod, 80))
end

-- Environmental phase changes (Melt/Freeze)
local function handle_phase_changes(pos, temp)
    if temp > 100 then
        local nodes = minetest.find_nodes_in_area(
            vector.subtract(pos, 1), vector.add(pos, 1), {"group:ice", "group:snow"}
        )
        for _, p in ipairs(nodes) do
            minetest.set_node(p, {name = "default:water_source"})
        end
    elseif temp < -20 then
        local water = minetest.find_nodes_in_area(
            vector.subtract(pos, 1), vector.add(pos, 1), {"group:water"}
        )
        for _, p in ipairs(water) do
            minetest.set_node(p, {name = "default:ice"})
        end
    end
end

-- Damage and Movement Debuffs
local function handle_damage_and_movement(player, playername, current_temp)
    if not player_monoids or not player_monoids.speed then return end

    player_monoids.speed:del_change(player, "ia_thermal:temp_penalty")

    if current_temp < TEMP_MIN_SAFE then
        local damage = math.ceil((TEMP_MIN_SAFE - current_temp) / 10)
        player:set_hp(player:get_hp() - damage)

        local penalty = math.max(0.3, 1.0 - (TEMP_MIN_SAFE - current_temp) * 0.02)
        player_monoids.speed:add_change(player, penalty, "ia_thermal:temp_penalty")
        minetest.chat_send_player(playername, string.format("Warning: Freezing! (%.1f°C)", current_temp))

    elseif current_temp > TEMP_MAX_SAFE then
        local damage = math.ceil((current_temp - TEMP_MAX_SAFE) / 10)
        player:set_hp(player:get_hp() - damage)
        minetest.chat_send_player(playername, string.format("Warning: Overheating! (%.1f°C)", current_temp))
    end
end

-- Main processing loop
local timer = 0
minetest.register_globalstep(function(dtime)
    timer = timer + dtime
    if timer < 1.0 then return end
    timer = 0

    for _, player in ipairs(ia_names.get_all_actors()) do
        if player and player:get_pos() then
            local t = ia_thermal.get_player_temp(player)
            local name = player:get_player_name()

            handle_damage_and_movement(player, name, t)
            handle_phase_changes(player:get_pos(), t)
        end
    end
end)
