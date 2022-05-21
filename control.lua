require("util")

local SIGNAL_DISPATCH = {type="virtual", name="dispatcher-station"}

-- Initiate global variables when activating the mod
script.on_init(function()
  -- Store all the train awaiting dispatch
  -- (we need to keep track of these trains in order to dispatch a train when a dispatch signal is sent)
  global.awaiting_dispatch = {}

  -- Store all the train that have been dispatched
  -- (we need to keep track of this in order to be able to reset the train schedule when it arrives at its destination)
  --global.dispatched = {}

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
    global.debug = true
    
    -- Build the list of stations on the map
    build_list_stations()
    -- Scrub train list to remove ones that don't exist anymore
    scrub_trains()
    
    if global.dispatched then
      if next(global.dispatched) then
        debug("Dispatcher: Warning! Could not migrate all dispatched trains. Please upload save file to the Dispatcher mod page.")
      else
        debug("Dispatcher: Completed migrating dispatched trains to temporary schedule records.")
        global.dispatched = nil
      end
    end
  end
end)


-- Add new station to global.stations if it meets our criteria
function add_station(entity)
  local name = entity.backer_name
  local id = entity.unit_number
  local surface_index = entity.surface.index
  if entity.name == "train-stop-dispatcher" or name:match("%.[123456789]%d*$") then
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
    debug("Ignoring new station: ", game.surfaces[surface_index].name.."/"..name)
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
    if global.awaiting_dispatch[previous_id] then
      -- Copy saved schedule from source to the cloned train, because it starts in manual mode
      local new_train = entity.train
      debug("Cloning saving schedule from train "..tostring(previous_id).." to train "..tostring(new_train.id)..": "..serpent.line(global.awaiting_dispatch[previous_id].schedule))
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
  for id,ad in pairs(global.awaiting_dispatch) do
    if not(ad.train and ad.train.valid) then
      global.awaiting_dispatch[id] = nil
      debug("Scrubbed train " .. id .. " from Awaiting Dispatch list.")
    end
  end
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
  
  -- A train that is awaiting dispatch cannot change state
  if global.awaiting_dispatch[id] then
    -- If the train mode has been set to manual mode, then we need to reset the train schedule
    if train.manual_mode then
      local schedule = global.awaiting_dispatch[id].schedule
      train.schedule = schedule
      debug("Train #", id, " set to manual mode while awaiting dispatch: schedule reset")
    else
      debug("Train #", id, " schedule changed while awaiting dispatch: train not awaiting dispatch anymore but schedule not reset")
    end
    global.awaiting_dispatch[id] = nil
  end
  
  local train_schedule = train.schedule

  -- Ensure that dispatched train are going to the chosen destination
  --if global.dispatched[id] and (not train_schedule or global.dispatched[id].current ~= train_schedule.current) then
  --  reset_station(id)
  --  debug("Train #", id, " is no longer being dispatched: schedule reset")
  --end

  -- When a train arrives at a dispatcher
  local train_station = train.station
  if train.state == defines.train_state.wait_station and train_station and train_station.name == "train-stop-dispatcher" then
    -- Add the train to the global variable storing all the trains awaiting dispatch
    global.awaiting_dispatch[id] = {train=train, station=train_station, schedule=train_schedule}
    -- Change the train schedule so that the train stays at the station
    train.schedule = {current=1, records={{station=train_station.backer_name, wait_conditions={{type="circuit", compare_type="or", condition={}}}}}}
    debug("Train #", id, " has arrived to dispatcher '", train_station.backer_name, "': awaiting dispatch")
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
    --d = nil
    --if global.dispatched[event.old_train_id_1] then
    --  d = global.dispatched[event.old_train_id_1]
    --elseif global.dispatched[event.old_train_id_2] then
    --  d = global.dispatched[event.old_train_id_2]
    --end
    --if d then
    --  if event.train.schedule then
    --    global.dispatched[event.train.id] = {train=event.train, station=d.station, current=d.current}
    --    event.train.manual_mode = false
    --    debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while being dispatched: new train #", event.train.id, " is being dispatched")
    --  else
    --    debug("Train #", event.old_train_id_1, " and #", event.old_train_id_2, " merged while being dispatched: new train #", event.train.id, " is no longer dispatched because it has no schedule")
    --  end
    --  global.dispatched[event.old_train_id_1] = nil
    --  global.dispatched[event.old_train_id_2] = nil
    --end
  elseif event.old_train_id_1 then
    if global.awaiting_dispatch[event.old_train_id_1] then
      ad = global.awaiting_dispatch[event.old_train_id_1]
      event.train.schedule = ad.schedule
      if has_locos(event.train) then
        event.train.manual_mode = false
        --global.dispatched[event.old_train_id_1] = nil
        debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while awaiting dispatch: train schedule reset, and mode set to automatic")
      else
        debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while awaiting dispatch: train schedule reset, and mode set to manual because it has no locomotives")
      end
    end
    --if global.dispatched[event.old_train_id_1] then
    --  if has_locos(event.train) then
    --    d = global.dispatched[event.old_train_id_1]
    --    global.dispatched[event.train.id] = {train=event.train, station=d.station, current=d.current}
    --    event.train.manual_mode = false
    --    global.dispatched[event.old_train_id_1] = nil
    --    debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while being dispatched: train schedule reset, and mode set to automatic")
    --  else
    --    debug("Train #", event.old_train_id_1, " was split to create train #", event.train.id, " while being dispatched: no longer dispatched, and mode set to manual because it has no locomotives")
    --  end
    --end
  end
end
script.on_event(defines.events.on_train_created, train_created)


-- Executed every tick
function tick()
  for i,v in pairs(global.awaiting_dispatch) do

    -- Ensure that the train still exists
    if not v.train.valid then
      global.awaiting_dispatch[i] = nil
      debug("Train #", i, " no longer exists: removed from awaiting dispatch list")

    -- Ensure that the dispatcher still exists, if not reset the train schedule
    elseif not v.station.valid then
      v.train.schedule = v.schedule
      global.awaiting_dispatch[i] = nil
      debug("Train #", v.train.id, " is awaiting at a dispatcher that no longer exists: schedule reset and train removed from awaiting dispatch list")

    else

      -- Get the dispatch signal at the dispatcher
      local signal = v.station.get_merged_signal(SIGNAL_DISPATCH)
      
      if signal then
        local name = v.station.backer_name .. "." .. tostring(signal)
        local surface_index = v.station.surface.index

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
            -- Stored schedule from train when it arrived
            local current = v.schedule.current
            local records = v.schedule.records

            -- Check if it was a temporary record that brought us here.
            if records[current].temporary then
              -- Replace this temporary record with another, keeping the same wait conditions
              records[current].station = name
            else
              -- Insert the destination station to the train schedule
              table.insert(records, current + 1, {station=name, wait_conditions=records[current].wait_conditions, temporary=true})
              current = current + 1
            end
            v.train.schedule = {current=current, records=records}
            v.train.manual_mode = false

            -- This train is not awaiting dispatch any more
            global.awaiting_dispatch[i] = nil

            -- If the train was sent to this dispatcher by another dispatcher, we need to update the train schedule and the dispatched variable
            --if global.dispatched[i] then
            --  reset_station(i)
            --end

            -- Store the dispatched train
            --global.dispatched[i] = {train=v.train, station=name, current=v.train.schedule.current}

            for _, player in pairs(game.players) do
              player.create_local_flying_text({text="Train dispatched to "..name, position=v.station.position, speed=1, time_to_live=200})
            end
            debug("Train #", v.train.id, " has been dispatched to station '", name, "'")
          else
            --debug("Train #", v.train.id, " can't find any enabled station '", name, "'")
          end
        else
          --debug("Train #", v.train.id, " can't find any station named '", name, "'")
        end
      end
    end
  end
end
script.on_event(defines.events.on_tick, tick)


-- Reset train schedule after a train has reached its destination
--function reset_station(id)
--  -- If new train has no schedule, do not give it one and remove it from dispatching list.
--  if global.dispatched[id].train.schedule then
--    local schedule = global.dispatched[id].train.schedule
--    
--    -- Only reset the train schedule if it has reached the correct station
--    if schedule.records[global.dispatched[id].current] and schedule.records[global.dispatched[id].current].station == global.dispatched[id].station and not schedule.records[global.dispatched[id].current].temporary then
--
--      -- Remove destination station from schedule
--      table.remove(schedule.records, global.dispatched[id].current)
--
--      -- If the current station is after the destination station
--      if schedule.current > global.dispatched[id].current then
--        schedule.current = schedule.current - 1
--      end
--
--      -- Reset train schedule
--      debug("Resetting train schedule for ID "..tostring(id))
--      global.dispatched[id].train.schedule = schedule
--      if has_locos(global.dispatched[id].train) then
--        global.dispatched[id].train.manual_mode = false
--      else
--        global.dispatched[id].train.manual_mode = true
--      end
--    end
--  end
--
--  global.dispatched[id] = nil
--end

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

------------------------------------------------------------------------------------
--                    FIND LOCAL VARIABLES THAT ARE USED GLOBALLY                 --
--                              (Thanks to eradicator!)                           --
------------------------------------------------------------------------------------
setmetatable(_ENV,{
  __newindex=function (self,key,value) --locked_global_write
    error('\n\n[ER Global Lock] Forbidden global *write*:\n'
      .. serpent.line{key=key or '<nil>',value=value or '<nil>'}..'\n')
    end,
  __index   =function (self,key) --locked_global_read
    error('\n\n[ER Global Lock] Forbidden global *read*:\n'
      .. serpent.line{key=key or '<nil>'}..'\n')
    end ,
  })

if script.active_mods["gvv"] then require("__gvv__.gvv")() end
