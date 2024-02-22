require "util"
require "lib"

max_fluid_flow_per_tick = 100
max_pollution_move_active = 128 -- the max amount of pollution that can be moved per 64 ticks from one surface to the above
max_pollution_move_passive = 64

suffocation_threshold = 1000
suffocation_damage = 2.5 -- per 64 ticks (~1 second)

miner_names = {
	"vehicle-miner", "vehicle-miner-mk2", "vehicle-miner-mk3", "vehicle-miner-mk4", "vehicle-miner-mk5",
	"vehicle-miner-0", "vehicle-miner-mk2-0", "vehicle-miner-mk3-0", "vehicle-miner-mk4-0", "vehicle-miner-mk5-0",
	"vehicle-miner-0-_-ghost", "vehicle-miner-mk2-0-_-ghost", "vehicle-miner-mk3-0-_-ghost", "vehicle-miner-mk4-0-_-ghost", "vehicle-miner-mk5-0-_-ghost",
	"vehicle-miner-0-_-solid", "vehicle-miner-mk2-0-_-solid", "vehicle-miner-mk3-0-_-solid", "vehicle-miner-mk4-0-_-solid", "vehicle-miner-mk5-0-_-solid"
}

function setup()
	global.subsurfaces = global.subsurfaces or {}
	global.pole_links = global.pole_links or {}
	global.car_links = global.car_links or {}
	global.surface_drillers = global.surface_drillers or {}
	global.item_elevators = global.item_elevators or {}
	global.fluid_elevators = global.fluid_elevators or {}
	global.air_vents = global.air_vents or {}
	global.air_vent_lights = global.air_vent_lights or {}
	global.exposed_chunks = global.exposed_chunks or {} -- [surface][x][y], 1 means chunk is exposed, 0 means chunk is next to an exposed chunk
	global.aai_miner_paths = global.aai_miner_paths or {}
end

script.on_init(setup)
script.on_configuration_changed(setup)

function get_subsurface(surface, create)
	if create == nil then create = true end
	if global.subsurfaces[surface.index] then -- the subsurface already exists
		return global.subsurfaces[surface.index]
	elseif create then -- we need to create the subsurface (pattern : <surface>_subsurface_<number>
		local name = ""
		local _, _, osname, number = string.find(surface.name, "(.+)_subsurface_([0-9]+)$")
		if osname == nil then name = surface.name .. "_subsurface_1"
		else name = osname .. "_subsurface_" .. (tonumber(number)+1) end
		
		local subsurface = game.get_surface(name)
		if not subsurface then
			local msg = surface.map_gen_settings
			subsurface = game.create_surface(name, msg)
			subsurface.generate_with_lab_tiles = true
			subsurface.daytime = 0.5
			subsurface.freeze_daytime = true
			subsurface.show_clouds = false
		end
		global.subsurfaces[surface.index] = subsurface
		return subsurface
	else return nil
	end
end
function get_oversurface(subsurface)
	for i,s in pairs(global.subsurfaces) do -- i is the index of the oversurface
		if s == subsurface and game.get_surface(i) then return game.get_surface(i) end
	end
	return nil
end

function get_subsurface_level(surface)
	local _, _, osname, number = string.find(surface.name, "(.+)_subsurface_([0-9]+)$")
	return tonumber(number)
end

function is_subsurface(surface)
	local name = ""
	if type(surface) == "table" then name = surface.name
	elseif type(surface) == "string" then name = surface
	elseif type(surface) == "number" then name = game.get_surface(surface).name
	end
	
	if string.find(name, "_subsurface_([0-9]+)$") or 0 > 1 then return true
	else return false end
end

function clear_subsurface(surface, pos, radius, clearing_radius)
	if not is_subsurface(surface) then return end
	local new_tiles = {}
	local walls_destroyed = 0

	if clearing_radius then -- destroy all entities in this radius except players
		local clearing_subsurface_area = get_area(pos, clearing_radius)
		for _,entity in ipairs(surface.find_entities(clearing_subsurface_area)) do
			if entity.type ~="player" then entity.destroy()
			else entity.teleport(get_safe_position(pos, {x=pos.x + clearing_radius, y = pos.y})) end
		end
	end
	
	for x, y in iarea(get_area(pos, radius)) do
		if surface.get_tile(x, y).valid and surface.get_tile(x, y).name == "out-of-map" then
			if (x-pos.x)^2 + (y-pos.y)^2 < radius^2 then
				table.insert(new_tiles, {name = "caveground", position = {x, y}})
				local wall = surface.find_entity("subsurface-wall", {x, y})
				if wall and wall.minable then
					wall.destroy()
					walls_destroyed = walls_destroyed + 1
				end
				
				-- add all surrounding chunks to exposed_chunks list, if not already present (0 in table) and delete this chunk
				local cx = math.floor(x / 32)
				local cy = math.floor(y / 32)
				global.exposed_chunks = global.exposed_chunks or {}
				global.exposed_chunks[surface.index] = global.exposed_chunks[surface.index] or {}
				if global.exposed_chunks[surface.index][cx] == nil then global.exposed_chunks[surface.index][cx] = {} end
				if global.exposed_chunks[surface.index][cx - 1] == nil then global.exposed_chunks[surface.index][cx - 1] = {} end
				if global.exposed_chunks[surface.index][cx + 1] == nil then global.exposed_chunks[surface.index][cx + 1] = {} end
				global.exposed_chunks[surface.index][cx][cy] = 1 -- this chunk is exposed
				-- surrounding chunks are set to 0 if not already exposed
				global.exposed_chunks[surface.index][cx - 1][cy] = global.exposed_chunks[surface.index][cx - 1][cy] or 0
				global.exposed_chunks[surface.index][cx + 1][cy] = global.exposed_chunks[surface.index][cx + 1][cy] or 0
				global.exposed_chunks[surface.index][cx][cy - 1] = global.exposed_chunks[surface.index][cx][cy - 1] or 0
				global.exposed_chunks[surface.index][cx][cy + 1] = global.exposed_chunks[surface.index][cx][cy + 1] or 0
				
			elseif math.abs((x-pos.x)^2 + (y-pos.y)^2) < (radius+1)^2 and surface.find_entity("subsurface-wall", {x, y}) == nil then
				local wall = surface.create_entity{name = "subsurface-wall", position = {x, y}, force=game.forces.neutral}
				-- now, if wall is outside map border, make it unminable
				if (remote.interfaces["space-exploration"] and math.sqrt(x*x + y*y) > remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = get_oversurface(surface).index}).radius - 5)
				or math.abs(x) + 1 > surface.map_gen_settings.width / 2 or math.abs(y) + 1 > surface.map_gen_settings.height / 2 then
					wall.minable = false
				end
			end
		end
	end
	
	surface.set_tiles(new_tiles)
	return walls_destroyed
end

script.on_event(defines.events.on_tick, function(event)
	
	-- handle all working drillers
	for i,d in ipairs(global.surface_drillers) do
		if not d.valid then table.remove(global.surface_drillers, i)
		elseif d.products_finished == 5 then -- time for one driller finish digging
			
			-- oversurface entity placing
			local p = d.position
			local entrance_car = d.surface.create_entity{name="tunnel-entrance", position={p.x+0.5, p.y+0.5}, force=d.force} -- because Factorio sets the entity at -0.5, -0.5
			local entrance_pole = d.surface.create_entity{name="tunnel-entrance-cable", position=p, force=d.force}
			table.remove(global.surface_drillers, i)
			
			-- subsurface entity placing
			local subsurface = get_subsurface(d.surface)
			global.exposed_chunks[subsurface.index] = {}
			clear_subsurface(subsurface, {x=d.position.x+0.5, y=d.position.y+0.5}, 4, 1.5)
			local exit_car = subsurface.create_entity{name="tunnel-exit", position={p.x+0.5, p.y+0.5}, force=d.force} -- because Factorio sets the entity at -0.5, -0.5

			local exit_pole = subsurface.create_entity{name="tunnel-exit-cable", position=p, force=d.force}
			
			entrance_pole.connect_neighbour(exit_pole)
			entrance_pole.connect_neighbour{wire=defines.wire_type.red, target_entity=exit_pole, source_circuit_id=1, target_circuit_id=1}
			entrance_pole.connect_neighbour{wire=defines.wire_type.green, target_entity=exit_pole, source_circuit_id=1, target_circuit_id=1}
			
			global.pole_links[entrance_pole.unit_number] = exit_pole
			global.pole_links[exit_pole.unit_number] = entrance_pole
			global.car_links[entrance_car.unit_number] = exit_car
			global.car_links[exit_car.unit_number] = entrance_car
			
			script.register_on_entity_destroyed(entrance_pole)
			script.register_on_entity_destroyed(exit_pole)
			script.register_on_entity_destroyed(entrance_car)
			script.register_on_entity_destroyed(exit_car)
			
			d.destroy()
		end
	end
	
	-- handle item elevators
	for i,elevators in ipairs(global.item_elevators) do  -- move items from input to output
		if not(elevators[1].valid and elevators[2].valid) then
			elevators[1].destroy()
			elevators[2].destroy()
			table.remove(global.item_elevators, i)
		else
			if elevators[1].get_item_count() > 0 and elevators[2].can_insert(elevators[1].get_inventory(defines.inventory.chest)[1]) then
				elevators[2].insert(elevators[1].get_inventory(defines.inventory.chest)[1])
				elevators[1].remove_item(elevators[1].get_inventory(defines.inventory.chest)[1])
			end
		end
	end
	
	-- handle fluid elevators
	for i,elevators in ipairs(global.fluid_elevators) do  -- average fluid between input and output
		if not(elevators[1].valid and elevators[2].valid) then
			elevators[1].destroy()
			elevators[2].destroy()
			table.remove(global.fluid_elevators, i)
		elseif elevators[1].fluidbox[1] then -- input has some fluid
			local f1 = elevators[1].fluidbox[1]
			local f2 = elevators[2].fluidbox[1] or {name=f1.name, amount=0, temperature=f1.temperature}
			if f1.name == f2.name then
				local diff = math.min(f1.amount, elevators[2].fluidbox.get_capacity(1) - f2.amount, max_fluid_flow_per_tick)
				f1.amount = f1.amount - diff
				f2.amount = f2.amount + diff
				if f1.amount == 0 then f1 = nil end
				elevators[1].fluidbox[1] = f1
				elevators[2].fluidbox[1] = f2
			end
		end
	end
	
	-- POLLUTION (since there is no mechanic to just reflect pollution (no absorption but also no spread) we have to do it for our own. The game's mechanic can't be changed so we need to consider it)
	if (event.tick - 1) % 64 == 0 then
		
		for _,subsurface in pairs(global.subsurfaces) do
			-- chunks that are not exposed but polluted distribute their pollution back to a chunk that is polluted (amount is proportional to adjacent chunks pollution)
			--for cx,cyt in pairs(global.exposed_chunks[subsurface.index] or {}) do
				--for cy,expval in pairs(cyt) do
				for chunk in subsurface.get_chunks() do
					local cx = chunk.x
					local cy = chunk.y
					local pollution = subsurface.get_pollution{cx*32, cy*32}
					if pollution > 0 and --[[expval == 0]]subsurface.count_tiles_filtered{area=chunk.area, name="caveground"} == 0 then
						local north = subsurface.get_pollution{cx*32, (cy-1)*32}
						local south = subsurface.get_pollution{cx*32, (cy+1)*32}
						local east = subsurface.get_pollution{(cx+1)*32, cy*32}
						local west = subsurface.get_pollution{(cx-1)*32, cy*32}
						local total = north + south + east + west
						if total > 0 then
							subsurface.pollute({cx*32, (cy-1)*32}, pollution*north/total)
							subsurface.pollute({cx*32, (cy+1)*32}, pollution*south/total)
							subsurface.pollute({(cx+1)*32, cy*32}, pollution*east/total)
							subsurface.pollute({(cx-1)*32, cy*32}, pollution*west/total)
							subsurface.pollute({cx*32, cy*32}, -pollution)
						end
					end
				end
			--end
			
		end
		
		-- next, move pollution using air vents
		for i,vent in ipairs(global.air_vents) do
			if vent.valid then
				local subsurface = get_subsurface(vent.surface)
				if vent.name == "active-air-vent" and vent.energy > 0 then
					local current_energy = vent.energy -- 918.5285 if full
					local max_energy = 918.5285
					local max_movable_pollution = max_pollution_move_active * (0.8 ^ (get_subsurface_level(subsurface) - 1)) * current_energy / max_energy -- how much polution can be moved with the current available energy
					
					local pollution_to_move = math.min(max_movable_pollution, subsurface.get_pollution(vent.position))
					
					--entity.energy = entity.energy - ((pollution_to_move / max_pollution_move_active)*max_energy)
					subsurface.pollute(vent.position, -pollution_to_move)
					vent.surface.pollute(vent.position, pollution_to_move)
					
					if pollution_to_move > 0 then
						vent.active = true
						vent.surface.create_trivial_smoke{name="light-smoke", position={vent.position.x+0.25, vent.position.y}, force=game.forces.neutral}
					else
						vent.active = false
					end
				elseif vent.name == "air-vent" then
					local pollution_surface = vent.surface.get_pollution(vent.position)
					local pollution_subsurface = subsurface.get_pollution(vent.position)
					local diff = pollution_surface - pollution_subsurface
					local max_movable_pollution = max_pollution_move_passive * (0.8 ^ (get_subsurface_level(subsurface) - 1))
					
					if math.abs(diff) > max_movable_pollution then
						diff = diff / math.abs(diff) * max_movable_pollution
					end

					if diff < 0 then -- pollution in subsurface is higher
						vent.surface.create_trivial_smoke{name="light-smoke", position={vent.position.x, vent.position.y}, force=game.forces.neutral}
					end

					vent.surface.pollute(vent.position, -diff)
					subsurface.pollute(vent.position, diff)
				end
			else
				table.remove(global.air_vents, i)
			end
		end
		
		-- player suffocation damage
		for _,p in pairs(game.players) do
			if p.connected and is_subsurface(p.surface) and p.surface.get_pollution(p.position) > suffocation_threshold then
				p.character.damage(suffocation_damage, game.forces.neutral, "poison")
				if (event.tick - 1) % 256 == 0 then p.print({"subsurface.suffocation"}, {1, 0, 0}) end
			end
		end
	end
	
	-- handle miners
	if remote.interfaces["aai-programmable-vehicles"] and event.tick % 10 == 0 then
		for _,subsurface in ipairs(global.subsurfaces) do
			
			for _,miner in ipairs(subsurface.find_entities_filtered{name=miner_names}) do
				
				-- navigation part
				local miner_data = remote.call("aai-programmable-vehicles", "get_unit_by_entity", miner)
				local path = nil
				if global.aai_miner_paths[miner_data.unit_id] and global.aai_miner_paths[miner_data.unit_id][1] > 0 then
					path = remote.call("aai-programmable-vehicles", "get_surface_paths", {surface_index=subsurface.index, force_name=miner.force.name})[global.aai_miner_paths[miner_data.unit_id][1]]
				end
				
				if path then
					local target_position = path.waypoints[global.aai_miner_paths[miner_data.unit_id][2]].position
					if miner_data.mode == "unit" and miner_data.speed == 0 then -- miner has no path (stucked)
						for _,p in ipairs(miner.force.players) do
							if event.tick % 180 == 0 then p.add_custom_alert(miner, {type="item", name=miner_data.unit_type}, {"subsurface.miner-stuck"}, true) end
						end
					elseif miner_data.mode == "vehicle" and not miner_data.vehicle.get_inventory(defines.inventory.car_trunk).is_full() then
						if miner.position.x - 2 < target_position.x and miner.position.x + 2 > target_position.x and miner.position.y - 2 < target_position.y and miner.position.y + 2 > target_position.y then
							local next_waypoint = path.first_waypoint_id
							for i,w in pairs(path.waypoints) do
								if next_waypoint == path.first_waypoint_id and i > global.aai_miner_paths[miner_data.unit_id][2] and path.waypoints[i] and path.waypoints[i].type == "position" then
									next_waypoint = i
								end
							end
							global.aai_miner_paths[miner_data.unit_id][2] = next_waypoint
						end
						remote.call("aai-programmable-vehicles", "set_unit_command", {unit_id=miner_data.unit_id, target_position_direct=path.waypoints[global.aai_miner_paths[miner_data.unit_id][2]].position})
					elseif miner_data.vehicle.get_inventory(defines.inventory.car_trunk).is_full() then
						for _,p in ipairs(miner.force.players) do
							if event.tick % 180 == 0 then p.add_custom_alert(miner, {type="item", name=miner_data.unit_type}, {"subsurface.miner-inventory-full"}, true) end
						end
						remote.call("aai-programmable-vehicles", "set_unit_command", {unit_id=miner_data.unit_id, target_speed=0})
					end
				else
					global.aai_miner_paths[miner_data.unit_id] = {0, 0}
				end
				
				if miner.valid and miner.speed > 0 then -- digging part
					local orientation = miner.orientation
					local miner_collision_box = miner.prototype.collision_box
					local center_big_excavation = move_towards_continuous(miner.position, orientation, -miner_collision_box.left_top.y)
					local center_small_excavation = move_towards_continuous(center_big_excavation, orientation, 1.7)
					local speed_test_position = move_towards_continuous(center_small_excavation, orientation, 1.5)
					
					local walls_dug = clear_subsurface(subsurface, center_small_excavation, 1, nil)
					walls_dug = walls_dug + clear_subsurface(subsurface, center_big_excavation, 3, nil)
					
					if walls_dug > 0 then
						local stack = {name = "stone", count = 20 * walls_dug}
						local actually_inserted = miner.insert(stack)
						if actually_inserted ~= stack.count then
							stack.count = stack.count - actually_inserted
							subsurface.spill_item_stack(miner.position, stack)
						end
					end

					local speed_test_tile = subsurface.get_tile(speed_test_position.x, speed_test_position.y)
					if miner.friction_modifier ~= 4 and miner.speed > 0 and speed_test_tile.name == "out-of-map" then
						miner.friction_modifier = 4
					end
					if miner.friction_modifier ~= 1 and not(miner.speed > 0 and speed_test_tile.name == "out-of-map") then
						miner.friction_modifier = 1
					end
				end
			end
		end
	end
end)

-- build entity only if it is safe in subsurface
function build_safe(event, func, check_for_entities)
	if check_for_entities == nil then check_for_entities = true end
	
	-- first, check if the given area is uncovered (caveground tiles) and has no entities in it
	local entity = event.created_entity
	local subsurface = get_subsurface(entity.surface)
	local area = entity.bounding_box
	local safe_position = true
	if not is_subsurface(subsurface) then safe_position = false end
	if not subsurface.is_chunk_generated{entity.position.x / 32, entity.position.y / 32} then safe_position = false end
	for _,t in ipairs(subsurface.find_tiles_filtered{area=area}) do
		if t.name ~= "caveground" then safe_position = false end
	end
	if check_for_entities and subsurface.count_entities_filtered{area=area} > 0 then safe_position = false end
	
	if safe_position then func()
	elseif event["player_index"] then
		local p = game.get_player(event.player_index)
		p.create_local_flying_text{text={"subsurface.cannot-place-here"}, position=entity.position}
		p.mine_entity(entity, true)
	else -- robot built it
		local it = entity.surface.create_entity{
			name = "item-on-ground",
			position = entity.position,
			force = entity.force,
			stack = {name=entity.name, count=1}
		}
		if it ~= nil then it.order_deconstruction(entity.force) end -- if it is nil, then the item is now on a belt
		for _,p in ipairs(entity.surface.find_entities_filtered{type="character", position=entity.position, radius=50}) do
			if p.player then p.player.create_local_flying_text{text={"subsurface.cannot-place-here"}, position=entity.position} end
		end
		entity.destroy()
	end
	
end
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, function(event)
	local entity = event.created_entity
	if entity.name == "surface-driller" then
		local text = ""
		if is_subsurface(entity.surface) and get_subsurface_level(entity.surface) >= settings.global["subsurface-limit"].value then
			text = "subsurface.limit-reached"
		elseif entity.surface.count_entities_filtered{name={"tunnel-entrance", "tunnel-exit"}, position=entity.position, radius=7} > 0 then
			text = "subsurface.cannot-place-here"
		end
		
		if text == "" then
			table.insert(global.surface_drillers, entity)
			get_subsurface(entity.surface).request_to_generate_chunks(entity.position, 3)
		else
			if event["player_index"] then
				local p = game.get_player(event.player_index)
				p.create_local_flying_text{text={text}, position=entity.position}
				p.mine_entity(entity, true)
			else -- robot built it
				local it = entity.surface.create_entity{
					name = "item-on-ground",
					position = entity.position,
					force = entity.force,
					stack = {name=entity.name, count=1}
				}
				if it ~= nil then it.order_deconstruction(entity.force) end -- if it is nil, then the item is now on a belt
				for _,p in ipairs(entity.surface.find_entities_filtered{type="character", position=entity.position, radius=50}) do
					if p.player then p.player.create_local_flying_text{text={text}, position=entity.position} end
				end
				entity.destroy()
			end
		end
	elseif entity.name == "item-elevator-input" then
		build_safe(event, function()
			local complementary = get_subsurface(entity.surface).create_entity{name="item-elevator-output", position=entity.position, force=entity.force, direction=entity.direction}
			if complementary then
				table.insert(global.item_elevators, {entity, complementary}) -- {input, output}
			end
		end)
	elseif entity.name == "item-elevator-output" then
		build_safe(event, function()
			local complementary = get_subsurface(entity.surface).create_entity{name="item-elevator-input", position=entity.position, force=entity.force, direction=entity.direction}
			if complementary then
				table.insert(global.item_elevators, {complementary, entity}) -- {input, output}
			end
		end)
	
	elseif entity.name == "fluid-elevator-input" then
		build_safe(event, function()
			local complementary = get_subsurface(entity.surface).create_entity{name = "fluid-elevator-output", position = entity.position, force=entity.force, direction=entity.direction}
			if complementary then
				table.insert(global.fluid_elevators, {entity, complementary}) -- {input, output}
			end
		end)
	elseif entity.name == "fluid-elevator-output" then
		build_safe(event, function()
			local complementary = get_subsurface(entity.surface).create_entity{name = "fluid-elevator-input", position = entity.position, force=entity.force, direction=entity.direction}
			if complementary then
				table.insert(global.fluid_elevators, {complementary, entity}) -- {input, output}
			end
		end)
	elseif entity.name == "air-vent" or entity.name == "active-air-vent" then
		build_safe(event, function()
			table.insert(global.air_vents, entity)
			entity.operable = false
			if not is_subsurface(entity.surface) then -- draw light in subsurface, but only if air vent is placed on surface
				global.air_vent_lights[script.register_on_entity_destroyed(entity)] = rendering.draw_light{surface=get_subsurface(entity.surface), target=entity.position, sprite="utility/light_small"}
			end
		end, false)
	end
end)

-- player elevator
script.on_event(defines.events.on_player_driving_changed_state, function(event)
	if event.entity and (event.entity.name == "tunnel-entrance" or event.entity.name == "tunnel-exit") and global.car_links and global.car_links[event.entity.unit_number] then
		local opposite_car = global.car_links[event.entity.unit_number]
		game.get_player(event.player_index).teleport(game.get_player(event.player_index).position, opposite_car.surface)
	end
end)

script.on_event(defines.events.on_chunk_generated, function(event)
	if is_subsurface(event.surface) then
		local newTiles = {}
		for x, y in iarea(event.area) do
			table.insert(newTiles, {name = "out-of-map", position = {x, y}})
		end
		event.surface.set_tiles(newTiles)
	end
end)

script.on_event(defines.events.on_player_mined_entity, function(event)
	if event.entity.name == "subsurface-wall" then
		clear_subsurface(event.entity.surface, event.entity.position, 1.5, nil)
	end
end)

-- AAI miner gui
script.on_event({defines.events.on_player_cursor_stack_changed, defines.events.on_player_changed_surface}, function(event)
	local player = game.get_player(event.player_index)
	local surface = player.surface
	if player.gui.left.aai_gui ~= nil then player.gui.left.aai_gui.destroy() end
	if player.cursor_stack ~= nil then
		if player.cursor_stack.valid_for_read and player.cursor_stack.name == "unit-remote-control" and is_subsurface(surface) then
			local miners = surface.find_entities_filtered{name=miner_names, force=player.force}
			if #miners > 0 then
				local miner_list = player.gui.left.add{
					type = "scroll-pane",
					name = "aai_gui",
					direction = "vertical",
					style = "aai_vehicles_units-scroll-pane"
				}
				for _,miner in ipairs(miners) do
					local miner_data = remote.call("aai-programmable-vehicles", "get_unit_by_entity", miner)
					local frame = miner_list.add{
						type = "frame",
						name = miner_data.unit_id,
						direction = "horizontal",
						style = "aai_vehicles_unit-frame"
					}
					frame.add{type="sprite", sprite="entity/"..miner_data.unit_type}
					frame.add{type="label", caption=miner_data.unit_id, style="aai_vehicles_unit-number-label"}
					
					local paths = remote.call("aai-programmable-vehicles", "get_surface_paths", {surface_index=surface.index, force_name=player.force.name})
					local path_names = {"None"}
					for _,p in ipairs(paths or {}) do
						path_names[p.path_id + 1] = p.path_id .. ": " .. p.name
					end
					frame.add{type="drop-down", name="miner_path", tags={unit_id=miner_data.unit_id}, items=path_names, selected_index=(global.aai_miner_paths[miner_data.unit_id] or {0, 0})[1] + 1}
				end
			end
		end
	end
end)
script.on_event(defines.events.on_gui_selection_state_changed, function(event)
	if event.element.name == "miner_path" then
		local unit_id = event.element.tags.unit_id
		if event.element.selected_index == 1 then
			global.aai_miner_paths[unit_id] = {0, 0}
		else
			global.aai_miner_paths[unit_id] = {event.element.selected_index - 1, remote.call("aai-programmable-vehicles", "get_surface_paths", {surface_index=game.get_player(event.player_index).surface.index, force_name=game.get_player(event.player_index).force.name})[event.element.selected_index - 1].first_waypoint_id}
		end
	end
end)

script.on_event(defines.events.on_pre_surface_deleted, function(event)
	-- delete all its subsurfaces and remove from list
	local i = event.surface_index
	while(global.subsurfaces[i]) do -- if surface i has a subsurface
		local s = global.subsurfaces[i] -- s is that subsurface
		global.subsurfaces[i] = nil -- remove from list
		i = s.index
		game.delete_surface(s) -- delete s
	end
	if is_subsurface(get_surface(event.surface_index)) then -- remove this surface from list
		global.subsurfaces[get_oversurface(game.get_surface(event.surface_index)).index] = nil
	end
end)

script.on_event(defines.events.on_entity_destroyed, function(event)
	-- entrances can't be mined, but in case they are destroyed by mods we have to handle it
	if global.pole_links[event.unit_number] and global.pole_links[event.unit_number].valid then
		local opposite_car = global.pole_links[event.unit_number].surface.find_entities_filtered{name={"tunnel-entrance", "tunnel-exit"}, position=global.pole_links[event.unit_number].position, radius=1}[1]
		if opposite_car and opposite_car.valid then opposite_car.destroy() end
		global.pole_links[event.unit_number].destroy()
		global.pole_links[event.unit_number] = nil
	elseif global.car_links[event.unit_number] and global.car_links[event.unit_number].valid then
		local opposite_pole = global.car_links[event.unit_number].surface.find_entities_filtered{name={"tunnel-entrance-cable", "tunnel-exit-cable"}, position=global.car_links[event.unit_number].position, radius=1}[1]
		if opposite_pole and opposite_pole.valid then opposite_pole.destroy() end
		global.car_links[event.unit_number].destroy()
		global.car_links[event.unit_number] = nil
	elseif global.air_vent_lights[event.registration_number] then
		rendering.destroy(global.air_vent_lights[event.registration_number])
		global.air_vent_lights[event.registration_number] = nil
	end
end)

script.on_event(defines.events.on_script_trigger_effect, function(event)
	if event.effect_id == "cliff-explosives" then
		local surface = game.get_surface(event.surface_index)
		for _,wall in ipairs(surface.find_entities_filtered{position=event.target_position, radius=3, name="subsurface-wall"}) do
			if wall.valid then
				local pos = wall.position
				clear_subsurface(surface, pos, 1, nil)
				surface.spill_item_stack(pos, {name="stone", count=20}, true, game.forces.neutral)
			end
		end
	end
end)

script.on_event("subsurface-position", function(event)
	local force = game.get_player(event.player_index).force
	local surface = game.get_player(event.player_index).surface
	if get_oversurface(surface) then force.print("[gps=".. string.format("%.1f,%.1f,", event.cursor_position.x, event.cursor_position.y) .. get_oversurface(surface).name .."]") end
	if get_subsurface(surface, false) then force.print("[gps=".. string.format("%.1f,%.1f,", event.cursor_position.x, event.cursor_position.y) .. get_subsurface(surface, false).name .."]") end
end)
