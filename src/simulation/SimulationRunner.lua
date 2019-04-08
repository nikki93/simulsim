local SimulationRunner = {}
function SimulationRunner:new(params)
  params = params or {}
  local simulation = params.simulation
  local framesOfHistory = params.framesOfHistory or 30
  local framesBetweenStateSnapshots = params.framesBetweenStateSnapshots or 5

  return {
    -- Private config vars
    _framesOfHistory = framesOfHistory,
    _framesBetweenStateSnapshots = framesBetweenStateSnapshots,

    -- Private vars
    _simulation = simulation,
    _stateHistory = {},
    _eventHistory = {},

    -- Public methods
    getSimulation = function(self)
      return self._simulation
    end,
    -- Adds an event to be applied on the given frame, which may trigger a rewind
    applyEvent = function(self, event)
      -- See if there already exists an event with that id
      local replacedEvent = false
      for i = #self._eventHistory, 1, -1 do
        if self._eventHistory[i].id == event.id then
          self._eventHistory[i] = event
          replacedEvent = true
          break
        end
      end
      -- Otherwise just insert it
      if not replacedEvent then
        table.insert(self._eventHistory, event)
      end
      -- If the event occurred too far in the past, there's not much we can do about it
      if event.frame < self._simulation.frame - self._framesOfHistory then
        return false
      -- If the event takes place in the past, regenerate the state history
      elseif event.frame <= self._simulation.frame then
        if not self:_regenerateStateHistoryOnOrAfterFrame(event.frame) then
          return false
        end
      end
      return true
    end,
    -- Cancels an event that was applied prior
    unapplyEvent = function(self, eventId)
      -- Search for the event
      for i = #self._eventHistory, 1, -1 do
        local event = self._eventHistory[i]
        if event.id == eventId then
          -- Remove the event
          table.remove(self._eventHistory, i)
          -- Regenerate state history if the event was applied in the past
          if event.frame <= self._simulation.frame then
            self:_regenerateStateHistoryOnOrAfterFrame(event.frame)
          end
          return true
        end
      end
      return false
    end,
    -- Sets the current state of the simulation, removing all past history in the process
    setState = function(self, state)
      -- Set the simulation's state
      self._simulation:setState(state)
      -- Only future events are still valid
      for i = #self._eventHistory, 1, -1 do
        if self._eventHistory[i].frame <= self._simulation.frame then
          table.remove(self._eventHistory, i)
        end
      end
      -- The only valid state is the current one
      self._stateHistory = {}
      self:_generateStateSnapshot()
    end,
    update = function(self, dt)
      -- TODO take dt into account
      self:_moveSimulationForwardOneFrame(true, true)
      self:_removeOldHistory()
      -- Return the number of frames that have been advanced
      return 1
    end,
    reset = function(self)
      self._simulation:reset()
      self._stateHistory = {}
      self._eventHistory = {}
    end,
    rewind = function(self, numFrames)
      if self:_rewindToFrame(self._simulation.frame - numFrames) then
        self:_invalidateStateHistoryOnOrAfterFrame(self._simulation.frame + 1)
        return true
      else
        return false
      end
    end,
    fastForward = function(self, numFrames)
      self:_fastForwardToFrame(self._simulation.frame + numFrames, true)
      return true
    end,

    -- Private methods
    -- Set the simulation to the state it was in after the given frame
    _rewindToFrame = function(self, frame)
      -- Get a state from before or on the given frame
      local mostRecentState = nil
      for _, state in ipairs(self._stateHistory) do
        if state.frame <= frame and (mostRecentState == nil or mostRecentState.frame < state.frame) then
          mostRecentState = state
        end
      end
      if mostRecentState then
        -- Set the simulation to that state
        self._simulation:setState(mostRecentState)
        -- Then fast forwad to the correct frame
        self:_fastForwardToFrame(frame, false)
        return true
      else
        -- The rewind could not occur
        return false
      end
    end,
    -- Fast forwards the simulation to the given frame
    _fastForwardToFrame = function(self, frame, shouldGenerateStateSnapshots)
      while self._simulation.frame < frame do
        self:_moveSimulationForwardOneFrame(false, shouldGenerateStateSnapshots)
      end
    end,
    -- Generates a state snapshot and adds it to the state history
    _generateStateSnapshot = function(self)
      table.insert(self._stateHistory, self._simulation:getState())
    end,
    -- Remove all state snapshots after the given frame
    _invalidateStateHistoryOnOrAfterFrame = function(self, frame)
      for i = #self._stateHistory, 1, -1 do
        if self._stateHistory[i].frame >= frame then
          table.remove(self._stateHistory, i)
        end
      end
    end,
    -- Invalidates and then regenerates all the state history after the given frame
    _regenerateStateHistoryOnOrAfterFrame = function(self, frame)
      local currFrame = self._simulation.frame
      -- Rewind to just before that frame
      if self:_rewindToFrame(frame - 1) then
        -- All the state snapshots on or after the given frame are invalid now
        self:_invalidateStateHistoryOnOrAfterFrame(frame)
        -- Then play back to the frame we were just at, generating state history as we go
        self:_fastForwardToFrame(currFrame, true)
        return true
      else
        return false
      end
    end,
    -- Advances the simulation forward one frame
    _moveSimulationForwardOneFrame = function(self, isTopFrame, shouldGenerateStateSnapshots)
      local dt = 1 / 60
      -- Advance the simulation's time
      self._simulation.frame = self._simulation.frame + 1
      -- Get the events that take place on this frame
      local events = self:_getEventsAtFrame(self._simulation.frame)
      -- Input-related events are automatically applied to the simulation's inputs
      local nonInputEvents = {}
      for _, event in ipairs(events) do
        if event.isInputEvent and event.type == 'set-inputs' then
          self._simulation.inputs[event.clientId] = event.data
        else
          table.insert(nonInputEvents, event)
          self._simulation:handleEvent(event.type, event.data)
        end
      end
      -- Update the simulation
      self._simulation:update(dt, self._simulation.inputs, nonInputEvents, isTopFrame)
      -- Generate a snapshot of the state every so often
      if shouldGenerateStateSnapshots and self._simulation.frame % self._framesBetweenStateSnapshots == 0 then
        self:_generateStateSnapshot()
      end
    end,
    -- Get all events that occurred at the given frame
    _getEventsAtFrame = function(self, frame)
      local events = {}
      for _, event in ipairs(self._eventHistory) do
        if event.frame == frame then
          table.insert(events, event)
        end
      end
      return events
    end,
    -- Removes any state snapshots and events that are beyond the history threshold
    _removeOldHistory = function(self)
      -- Remove old state history
      for i = #self._stateHistory, 1, -1 do
        if self._stateHistory[i].frame < self._simulation.frame - self._framesOfHistory - self._framesBetweenStateSnapshots then
          table.remove(self._stateHistory, i)
        end
      end
      -- Remove old event history
      for i = #self._eventHistory, 1, -1 do
        if self._eventHistory[i].frame < self._simulation.frame - self._framesOfHistory - self._framesBetweenStateSnapshots then
          table.remove(self._eventHistory, i)
        end
      end
    end
  }
end

return SimulationRunner
