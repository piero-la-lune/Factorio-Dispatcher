SIGNAL_DISPATCH = {type="virtual", name="dispatcher-station"}

-- Initiate global variables when activating the mod
script.on_init(function()
  -- Store all the train awaiting dispatch
  -- (we need to keep track of these trains in order to dispatch a train when a dispatch signal is sent)
  global.awaiting_dispatch = {}

  -- Store all the train that have been dispatched
  -- (we need to keep track of this in order to be able to reset the train schedule when it arrives at its destination)
  global.dispatched = {}
end)

-- Ensure the ticker is on when loading a map
script.on_load(function()
  activateTicker()
end)


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
    activateTicker()
  end
end
script.on_event(defines.events.on_train_changed_state, train_changed_state)


-- Activate/Deactivate ticker (every 4 ticks)
function activateTicker()
  if next(global.awaiting_dispatch) ~= nil then
    script.on_nth_tick(4, tick)
  else
    script.on_nth_tick(nil)
  end
end


-- Executed every 4 ticks
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

        -- Build list of stations and dispatchers
        local stations = game.surfaces["nauvis"].find_entities_filtered{name= "train-stop"}
        local dispatchers = game.surfaces["nauvis"].find_entities_filtered{name= "train-stop-dispatcher"}
        for _, s in pairs(dispatchers) do
          table.insert(stations, s)
        end

        -- Search for the destination station
        for _, station in pairs(stations) do
          if station.backer_name == v.station.backer_name .. "." .. tostring(signal) then
            local current = v.schedule.current
            local records = v.schedule.records
            
            -- Insert the destination station to the train schedule
            table.insert(records, current + 1, {station=station.backer_name, wait_conditions=records[current].wait_conditions })
            v.train.schedule = {current=current + 1, records=records}
            v.train.manual_mode = false

            -- This train is not awaiting dispatch any more
            global.awaiting_dispatch[i] = nil

            -- If the train was sent to this dispatcher by another dispatcher, we need to update the train schedule and the dispatched variable
            if global.dispatched[i] ~= nil then
              reset_station(i)
            end

            -- Store the dispatched train
            global.dispatched[i] = {train=v.train, station=station.backer_name, current=v.train.schedule.current}
          end
        end
      end
    end
  end

  -- Stop the ticker if there is no more awaiting dispatch trains
  if next(global.awaiting_dispatch) == nil then
    script.on_nth_tick(nil)
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