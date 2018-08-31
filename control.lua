SIGNAL_DISPATCH = {type="virtual", name="dispatcher-station"}

-- Initiate global variables when activating the mod
script.on_init(function()
  -- Store all the train awaiting dispatch
  -- (we need to keep track of these trains in order to dispatch a train when a dispatch signal is sent)
  global.awaiting_dispatch = {}

  -- Store all the train that have been dispatched
  -- (we need to keep track of this in order to be able to reset the train schedule when it arrives at its destination)
  global.dispatched = {}

  -- Store all the stations
  -- (we need it for performance reasons)
  global.stations = {}
end)


-- When map is loaded
script.on_load(function()
  script.on_nth_tick(300, update_list_stations)
end)


-- When configuration is changed (new mod version, etc.)
script.on_configuration_changed(function(data)
  if data.mod_changes and data.mod_changes.Dispatcher then
    local old_version = data.mod_changes.Dispatcher.old_version
    local new_version = data.mod_changes.Dispatcher.new_version

    -- If mod not activated before
    if not old_version and new_version then
      build_list_stations()
    end

    -- New mod version
    if old_version and new_version then
      if old_version < "1.0.1" then
        build_list_stations()
      end
    end
  end
end)


-- Add new stations to global.stations
function entity_built(event)
  if event.created_entity.name == "train-stop" or event.created_entity.name == "train-stop-dispatcher" then
    global.stations[event.created_entity.backer_name] = event.created_entity
  end
end
script.on_event(defines.events.on_built_entity, entity_built)
script.on_event(defines.events.on_robot_built_entity, entity_built)


-- Remove mined stations from global.stations
function entity_removed(event)
  if event.entity.name == "train-stop" or event.entity.name == "train-stop-dispatcher" then
    global.stations[event.entity.backer_name] = nil
  end
end
script.on_event(defines.events.on_player_mined_entity, entity_removed)
script.on_event(defines.events.on_robot_mined_entity, entity_removed)
script.on_event(defines.events.on_entity_died, entity_removed)


-- Track train state change
function train_changed_state(event)
  local id = event.train.id

  -- A train that is awaiting dispatch cannot change state
  if global.awaiting_dispatch[id] ~= nil then
    -- If the train mode has been set to manual mode, then we need to reset the train schedule
    if event.train.manual_mode then
      local schedule = global.awaiting_dispatch[id].schedule
      event.train.schedule = schedule
    end
    global.awaiting_dispatch[id] = nil
  end

  -- Ensure that dispatched train are going to the chosen destination
  if global.dispatched[id] ~= nil and global.dispatched[id].current ~= event.train.schedule.current then
    reset_station(id)
  end

  -- When a train arrives at a dispatcher
  if event.train.state == defines.train_state.wait_station and event.train.station.name == "train-stop-dispatcher" then
    -- Add the train to the global variable storing all the trains awaiting dispatch
    global.awaiting_dispatch[id] = {train=event.train, station=event.train.station, schedule=event.train.schedule}

    -- Change the train schedule so that the train stays at the station
    event.train.schedule = {current=1, records={{station=event.train.station.backer_name, wait_conditions={{type="circuit", compare_type="or", condition={}}}}}}
  end
end
script.on_event(defines.events.on_train_changed_state, train_changed_state)


-- Executed every tick
function tick()
  for i,v in pairs(global.awaiting_dispatch) do

    -- Ensure that the train still exists
    if not v.train.valid then
      global.awaiting_dispatch[i] = nil

    -- Ensure that the dispatcher still exists, if not reset the train schedule
    elseif not v.station.valid then
      v.train.schedule = v.schedule
      global.awaiting_dispatch[i] = nil

    else

      -- Get the dispatch signal at the dispatcher
      local signal = get_signal(v.station, SIGNAL_DISPATCH)

      if signal ~= nil then
        local name = v.station.backer_name .. "." .. tostring(signal)

        if global.stations[name] ~= nil  then
          local current = v.schedule.current
          local records = v.schedule.records
            
          -- Insert the destination station to the train schedule
          table.insert(records, current + 1, {station=name, wait_conditions=records[current].wait_conditions })
          v.train.schedule = {current=current + 1, records=records}
          v.train.manual_mode = false

          -- This train is not awaiting dispatch any more
          global.awaiting_dispatch[i] = nil

          -- If the train was sent to this dispatcher by another dispatcher, we need to update the train schedule and the dispatched variable
          if global.dispatched[i] ~= nil then
            reset_station(i)
          end

          -- Store the dispatched train
          global.dispatched[i] = {train=v.train, station=name, current=v.train.schedule.current}
        end
      end
    end
  end
end
script.on_event(defines.events.on_tick, tick)


-- Update list of stations (because players can change station names)
function update_list_stations()
  new_stations = {}
  for name, station in pairs(global.stations) do
    if not station.valid then
      global.stations[name] = nil
    else
      if station.backer_name ~= name then
        global.stations[name] = nil
        new_stations[station.backer_name] = station
      end
    end
  end
  for name, station in pairs(new_stations) do
    global.stations[name] = station
  end
end
function build_list_stations()
  global.stations = {}
  local stations = game.surfaces["nauvis"].find_entities_filtered{name= "train-stop"}
  for _, station in pairs(stations) do
    global.stations[station.backer_name] = station
  end
  local dispatchers = game.surfaces["nauvis"].find_entities_filtered{name= "train-stop-dispatcher"}
  for _, station in pairs(dispatchers) do
    global.stations[station.backer_name] = station
  end
end


-- Reset train schedule after a train has reached its destination
function reset_station(id)
  local records = global.dispatched[id].train.schedule.records
  local current = global.dispatched[id].train.schedule.current

  -- Only reset the train schedule if it has reached the correct station
  if records[global.dispatched[id].current] ~= nil and records[global.dispatched[id].current].station == global.dispatched[id].station then

    -- Remove destination station from schedule
    table.remove(records, global.dispatched[id].current)

    -- If the current station is after the destination station
    if current > global.dispatched[id].current then
      current = current - 1
    end

    -- Reset train schedule
    global.dispatched[id].train.schedule = {current=current, records=records}
    global.dispatched[id].train.manual_mode = false
  end

  global.dispatched[id] = nil
end


-- Get red and green signal for given entity and signal
function get_signal(entity, signal)
  local red = entity.get_circuit_network(defines.wire_type.red)
  local green = entity.get_circuit_network(defines.wire_type.green)
  local value = nil
  if red then
    value = red.get_signal(signal)
  end
  if green then
    if value == nil then
      value = green.get_signal(signal)
    else
      value = value + green.get_signal(signal)
    end
  end
  return value
end


-- Debug (print text to player console)
function debug(text)
  local first_player = game.players[1]
  first_player.print(text)
end