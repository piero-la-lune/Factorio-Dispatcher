require("util")

local NAME_DISPATCHER_ENTITY = "train-stop-dispatcher"
local SIGNAL_DISPATCH = {type="virtual", name="dispatcher-station"}
local NAME_SEPARATOR = "."
local NAME_SEPARATOR_REGEX = "%."

-- Initiate global variables when activating the mod
script.on_init(function()
  -- Store all the train awaiting dispatch
  -- (we need to keep track of these trains in order to dispatch a train when a dispatch signal is sent)
  global.awaiting_dispatch = {}

  -- Store all the stations per surface
  -- (we need it cached for performance reasons)
  global.stations = {}

  global.debug = false
end)


-- When configuration is changed (new mod version, etc.)
script.on_configuration_changed(function(data)
  if data.mod_changes and data.mod_changes.Dispatcher then
    local old_version = data.mod_changes.Dispatcher.old_version
    local new_version = data.mod_changes.Dispatcher.new_version

    -- Mod version upgraded
    if old_version then
      if old_version < "1.0.2" then
        global.debug = false
      end
    end

    local debug_temp = global.debug
    global.debug = true

    -- Build the list of stations on the map
    build_list_stations()
    -- Scrub train list to remove ones that don't exist anymore
    scrub_trains()

    -- Complete the migration if no dispatched trains remain in list
    if global.dispatched then
      if next(global.dispatched) then
        debug("Dispatcher: WARNING! Could not migrate all dispatched trains. Please upload save file to the Dispatcher mod page.")
      else
        debug("Dispatcher: Completed migrating dispatched trains to temporary schedule records.")
        global.dispatched = nil
      end
    end

    global.debug = debug_temp
  end
end)


-- Add new station to global.stations if it meets our criteria
function add_station(entity)
  local name = entity.backer_name
  local id = entity.unit_number
  local surface_index = entity.surface.index
  if entity.name == NAME_DISPATCHER_ENTITY or name:match(NAME_SEPARATOR_REGEX.."[123456789]%d*$") then
    if not global.stations[surface_index] then
      global.stations[surface_index] = {}
    end
    if not global.stations[surface_index][name] then
      global.stations[surface_index][name] = {}
      global.stations[surface_index][name][id] = entity
      debug("Added first station: ", game.surfaces[surface_index].name.."/"..name)
    else
      global.stations[surface_index][name][id] = entity
      debug("Added station: ", game.surfaces[surface_index].name.."/"..name)
    end
  else
    --debug("Ignoring new station: ", game.surfaces[surface_index].name.."/"..name)
  end
end

-- Remove station from global.stations if it is in the list
function remove_station(entity, old_name)
  local name = old_name or entity.backer_name
  local id = entity.unit_number
  local surface_index = entity.surface.index
  if global.stations[surface_index] and global.stations[surface_index][name] and global.stations[surface_index][name][id] then
    global.stations[surface_index][name][id] = nil
    if not next(global.stations[surface_index][name]) then
      global.stations[surface_index][name] = nil
      debug("Removed last station named: ", game.surfaces[surface_index].name.."/"..name)
      if not next(global.stations[surface_index]) then
        global.stations[surface_index] = nil
        debug("Removed last station from surface "..game.surfaces[surface_index].name)
      end
    else
      debug("Removed station: ", game.surfaces[surface_index].name.."/"..name)
    end
  end
end

-- Add stations when built/revived
function entity_built(event)
  local entity = event.created_entity or event.entity
  add_station(entity)
end
script.on_event(defines.events.on_built_entity, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.on_robot_built_entity, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.script_raised_built, entity_built, {{filter="type", type="train-stop"}})
script.on_event(defines.events.script_raised_revive, entity_built, {{filter="type", type="train-stop"}})

-- Add station or copy train data when cloned
function entity_cloned(event)
  local entity = event.destination
  if entity.type == "train-stop" then
    add_station(entity)
  elseif entity.type == "locomotive" and event.source then
    local previous_id = event.source.train.id
    if global.awaiting_dispatch[previous_id] and global.awaiting_dispatch[previous_id].schedule then
      -- Copy saved schedule from source to the cloned train, because it starts in manual mode
      local new_train = entity.train
      debug("Cloning saved schedule from train "..tostring(previous_id).." to train "..tostring(new_train.id)..": "..serpent.line(global.awaiting_dispatch[previous_id].schedule))
      new_train.schedule = global.awaiting_dispatch[previous_id].schedule
    end
  end
end
script.on_event(defines.events.on_entity_cloned, entity_cloned, {{filter="type", type="train-stop"}, {filter="type", type="locomotive"}})

-- Remove station when mined/destroyed
function entity_removed(event)
  remove_station(event.entity)
end
script.on_event(defines.events.on_player_mined_entity, entity_removed, {{filter="type", type="train-stop"}})
script.on_event(defines.events.on_robot_mined_entity, entity_removed, {{filter="type", type="train-stop"}})
script.on_event(defines.events.on_entity_died, entity_removed, {{filter="type", type="train-stop"}})
script.on_event(defines.events.script_raised_destroy, entity_removed, {{filter="type", type="train-stop"}})

-- Update station when renamed by player or script
function entity_renamed(event)
  local entity = event.entity
  if entity.type == "train-stop" then
    remove_station(entity, event.old_name)
    add_station(entity)
  end
end
script.on_event(defines.events.on_entity_renamed, entity_renamed)


-- Build list of stations
function build_list_stations()
  global.stations = {}
  for _,surface in pairs(game.surfaces) do
    local stations = surface.get_train_stops()
    for _,station in pairs(stations) do
      add_station(station)
    end
  end
  debug("Stations list rebuilt")
end


-- Scrub list of trains
function scrub_trains()
  -- Look for trains awaiting dispatch that disappeared during configuration change
  for id,ad in pairs(global.awaiting_dispatch) do
    if not(ad.train and ad.train.valid) then
      global.awaiting_dispatch[id] = nil
      debug("Scrubbed train " .. id .. " from Awaiting Dispatch list.")
    end
  end
  -- Migrate currently dispatched trains to use temporary stops, so we don't have to track them anymore
  if global.dispatched then
    for id,d in pairs(global.dispatched) do
      if not(d.train and d.train.valid) then
        global.dispatched[id] = nil
        debug("Scrubbed train " .. id .. " from Dispatched list.")
      else
        -- Migrate schedule to use a temporary stop
        local schedule = d.train.schedule
        if schedule.records[d.current] and schedule.records[d.current].station == d.station then
          schedule.records[schedule.current].temporary = true
          d.train.schedule = schedule
          global.dispatched[id] = nil
          debug("Converted train "..id.." to temporary destination and removed from Dispatched list.")
        else
          debug("Did not convert train"..id.." to temporary destination.")
        end
      end
    end
  end
end


-- Track train state change
function train_changed_state(event)
  local train = event.train
  local id = train.id

  -- A train that is awaiting dispatch cannot change state. Restore schedule if appropriate
  if global.awaiting_dispatch[id] then
    local station_name = global.awaiting_dispatch[id].station_name
    local train_schedule = train.schedule
    if global.awaiting_dispatch[id].schedule then
      -- There is a stored schedule, restore it
      local schedule = global.awaiting_dispatch[id].schedule
      train.schedule = schedule
      if train.manual_mode then
        debug("Train #", id, " set to manual mode while awaiting dispatch: schedule reset")
      elseif not global.awaiting_dispatch[id].station or not global.awaiting_dispatch[id].station.valid then
        debug("Train #", id, " was waiting at a dispatcher that no longer exists: schedule reset")
      else
        debug("Train #", id, " left the dispatcher: schedule reset")
      end
    else
      -- Schedule was either completely overwritten, or player sent train to another stop
      -- Try to find the temporary waiting station we added and remove it
      local found = false
      for i=1,#train_schedule.records do
        if train_schedule.records[i].temporary and train_schedule.records[i].station == station_name then
          table.remove(train_schedule.records, i)
          -- If train was pathing to the waiting stop, send it to the previous record (the actual dispatcher arrival)
          if train_schedule.current >= i then
            train_schedule.current = train_schedule.current - 1
          end
          found = true
          break
        end
      end
      if found then
        train.schedule = train_schedule
        if train.manual_mode then
          debug("Train #", id, " set to manual mode while awaiting dispatch: schedule reset")
        elseif not global.awaiting_dispatch[id].station or not global.awaiting_dispatch[id].station.valid then
          debug("Train #", id, " was waiting at a dispatcher that no longer exists: schedule reset")
        else
          debug("Train #", id, " left the dispatcher: schedule reset")
        end
      else
        debug("Dispatcher: WARNING! Train #", id, " no longer awaiting dispatch but schedule was not reset.")
      end
    end
    global.awaiting_dispatch[id] = nil
  end

  -- When a train arrives at a dispatcher
  local train_station = train.station
  if train.state == defines.train_state.wait_station and train_station and train_station.name == NAME_DISPATCHER_ENTITY then
    -- Add the train to the global variable storing all the trains awaiting dispatch
    local station_name = train_station.backer_name
    global.awaiting_dispatch[id] = {train=train, station=train_station, station_name=station_name}

    -- Change the train schedule so that the train stays at the station
    local wait_schedule = train.schedule
    table.insert(wait_schedule.records, wait_schedule.current + 1,
      {station=station_name, temporary=true, wait_conditions={{type="circuit", compare_type="or", condition={}}}})
    wait_schedule.current = wait_schedule.current + 1
    train.schedule = wait_schedule
    debug("Train #", id, " has arrived to dispatcher ", train_station.surface.name, "/", station_name, ": awaiting dispatch")
  end
end
script.on_event(defines.events.on_train_changed_state, train_changed_state)


-- Track uncoupled trains (because the train id changes)
function train_created(event)
  local ad
  if event.old_train_id_1 and event.old_train_id_2 then
    if global.awaiting_dispatch[event.old_train_id_1] then
      ad = global.awaiting_dispatch[event.old_train_id_1]
    elseif global.awaiting_dispatch[event.old_train_id_2] then
      ad = global.awaiting_dispatch[event.old_train_id_2]
    end
    if ad then
      if event.train.schedule then
        event.train.schedule = ad.schedule
        event.train.manual_mode = false
        global.awaiting_dispatch[event.train.id] = nil
        debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while awaiting dispatch: new train #", event.train.id, " schedule reset, and mode set to automatic")
      else
        debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while awaiting dispatch: new train #", event.train.id, " set to manual because it has no schedule")
      end
      global.awaiting_dispatch[event.old_train_id_2] = nil
      global.awaiting_dispatch[event.old_train_id_1] = nil
    end
  elseif event.old_train_id_1 then
    if global.awaiting_dispatch[event.old_train_id_1] then
      ad = global.awaiting_dispatch[event.old_train_id_1]
      event.train.schedule = ad.schedule
      if has_locos(event.train) then
        event.train.manual_mode = false
        debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while awaiting dispatch: train schedule reset, and mode set to automatic")
      else
        debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while awaiting dispatch: train schedule reset, and mode set to manual because it has no locomotives")
      end
    end
  end
end
script.on_event(defines.events.on_train_created, train_created)


-- Executed every tick
function tick()
  for id,ad in pairs(global.awaiting_dispatch) do

    -- Ensure that the train still exists
    if not ad.train or not ad.train.valid then
      global.awaiting_dispatch[id] = nil
      debug("Train #", id, " no longer exists: removed from awaiting dispatch list")

    else
      -- Get the dispatch signal at the dispatcher, check if it is a positive number
      local signal = ad.station.get_merged_signal(SIGNAL_DISPATCH)

      if signal and signal > 0 then
        local dispatcher_name = ad.station.backer_name
        local name = dispatcher_name .. NAME_SEPARATOR .. tostring(signal)
        local surface = ad.station.surface
        local surface_index = surface.index

        if global.stations[surface_index] and global.stations[surface_index][name] then

          -- Search for valid destination station
          local found = false
          for _,station in pairs(global.stations[surface_index][name]) do
            -- Check that the station exists
            if station.valid then
              local cb = station.get_control_behavior()
              -- Check that the station in not disabled
              if not cb or not cb.disabled then
                found = true
                break
              end
            end
          end

          if found then
            -- Get schedule of waiting train
            local train_schedule = ad.train.schedule
            if (train_schedule.current > 1 and
                train_schedule.records[train_schedule.current].temporary and
                train_schedule.records[train_schedule.current-1].station == dispatcher_name) then

              -- Currently at a temporary waiting stop. Delete it.
              table.remove(train_schedule.records, train_schedule.current)
              train_schedule.current = train_schedule.current - 1

            elseif ad.schedule then
              -- Waiting at a real stop or the schedule got messed up. Use stored schedule
              train_schedule = ad.schedule

            else
              debug("Dispatcher: WARNING! Train "..id.." waiting at "..dispatcher_name.." could not be dispatched because schedule is missing.")
              train_schedule = nil
            end

            if train_schedule then
              if train_schedule.records[train_schedule.current].temporary then
                -- Arrived at this dispatcher with a temporary stop. Replace it with the dispatched destination, conditions stay the same.
                train_schedule.records[train_schedule.current].station = name
              else
                -- Arrived at this dispatcher with a permanent stop. Add the temporary dispatched destination and copy the conditions.
                table.insert(train_schedule.records, train_schedule.current + 1,
                  {station=name, temporary=true, wait_conditions=train_schedule.records[train_schedule.current].wait_conditions} )
                train_schedule.current = train_schedule.current + 1
              end

              ad.train.schedule = train_schedule
              ad.train.manual_mode = false

              for _, player in pairs(game.players) do
                if player.surface == surface then
                  player.create_local_flying_text({text={"dispatcher.train-dispatched-message",id,name}, position=ad.station.position, speed=1, time_to_live=200})
                end
              end
              debug("Train #", id, " has been dispatched to station "..surface.name.."/"..name)
            end

            -- This train is not awaiting dispatch any more
            global.awaiting_dispatch[id] = nil

          else
            --debug("Train #", ad.train.id, " can't find any enabled station '", name, "'")
          end
        else
          --debug("Train #", ad.train.id, " can't find any station named '", name, "'")
        end
      end
    end
  end
end
script.on_event(defines.events.on_tick, tick)

-- Check for any locomotives in the train
function has_locos(train)
  if next(train.locomotives.front_movers) then
    return true
  end
  if next(train.locomotives.back_movers) then
    return true
  end
  return false
end


function any_to_string(...)
  local text = ""
  for _, v in ipairs{...} do
    if type(v) == "table" then
      text = text..serpent.block(v)
    else
      text = text..tostring(v)
    end
  end
  return text
end

function print_game(...)
  game.print(any_to_string(...))
end

-- Debug (print text to player console)
function debug(...)
  if global.debug then
    print_game(...)
  end
end

-- Debug command
function cmd_debug(params)
  local toggle = params.parameter
  if not toggle then
    if global.debug then
      toggle = "disable"
    else
      toggle = "enable"
    end
  end
  if toggle == "disable" then
    global.debug = false
    print_game("Debug mode disabled")
  elseif toggle == "enable" then
    global.debug = true
    print_game("Debug mode enabled")
  elseif toggle == "dump" then
    for v, data in pairs(global) do
      print_game(v, ": ", data)
    end
  elseif toggle == "dumplog" then
    for v, data in pairs(global) do
      log(any_to_string(v, ": ", data))
    end
    print_game("Dump written to log file")
  end
end
commands.add_command("dispatcher-debug", {"command-help.dispatcher-debug"}, cmd_debug)

if script.active_mods["gvv"] then require("__gvv__.gvv")() end
