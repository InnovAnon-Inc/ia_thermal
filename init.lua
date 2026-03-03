-- ia_thermal/init.lua

-- Configuration
local TEMP_MIN_SAFE = 0   -- Degrees Celsius (Freezing)
local TEMP_MAX_SAFE = 45  -- Degrees Celsius (Heatstroke)
local SEA_LEVEL = 0
local LAPSE_RATE = 6.5    -- Temp drop per 1000 nodes (Matches Earth's troposphere)

local ia_thermal = {}

-- Configuration
local TEMP_MIN_SAFE = 0    -- 0°C
local TEMP_MAX_SAFE = 45   -- 45°C
local SEA_LEVEL = 0
local LAPSE_RATE = 6.5     -- 6.5°C drop per 1000 nodes (Upward)
local GEO_GRADIENT = 15    -- 15°C rise per 1000 nodes (Downward)

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

local timer = 0
minetest.register_globalstep(function(dtime)
    timer = timer + dtime
    if timer < 1.0 then return end
    timer = 0

    for _, player in ipairs(ia_names.get_all_actors()) do
        local t = ia_thermal.get_player_temp(player)
        local name = player:get_player_name()

        -- Reset speed penalty by default (using a unique ID for this mod)
        player_monoids.speed:del_change(player, "ia_thermal:temp_penalty")

        if t < TEMP_MIN_SAFE then
            -- 1. Damage Logic
            local damage = math.ceil((TEMP_MIN_SAFE - t) / 10)
            player:set_hp(player:get_hp() - damage)

            -- 2. Sluggishness (Built-in Monoid)
            -- Reduce speed by 10% for every 5 degrees below freezing
            local penalty = math.max(0.3, 1.0 - (TEMP_MIN_SAFE - t) * 0.02)
            player_monoids.speed:add_change(player, penalty, "ia_thermal:temp_penalty")

            minetest.chat_send_player(name, string.format("Warning: Freezing! Speed reduced. (%.1f°C)", t))

        elseif t > TEMP_MAX_SAFE then
            local damage = math.ceil((t - TEMP_MAX_SAFE) / 10)
            player:set_hp(player:get_hp() - damage)

	    -- NOTE minimal test server with only {,more_}player_monoids enabled crashes at start
            -- Use the Saturation Monoid from your library to simulate heat dizziness
            --if more_player_monoids.saturation then
            --    more_player_monoids.saturation:add_change(player, 0.5, "ia_thermal:heat_haze")
            --end

            minetest.chat_send_player(name, string.format("Warning: Overheating! (%.1f°C)", t))
        else
	    -- NOTE minimal test server with only {,more_}player_monoids enabled crashes at start
            -- Clean up heat effects if safe
            --if more_player_monoids.saturation then
            --    more_player_monoids.saturation:del_change(player, "ia_thermal:heat_haze")
            --end
        end
    end
end)





-- TODO freeze liquids
-- TODO melt solids
-- TODO phase changes, basically
-- TODO ignite combustibles
