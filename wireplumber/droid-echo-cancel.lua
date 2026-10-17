-- SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
-- SPDX-License-Identifier: MIT
-- Echo cancellation for calls in apps.
--
-- A mobile call has the modem's own canceller. Everything else had none: a
-- voice chat in Firefox over the speaker heard itself, measured 2026-10-17
-- with the Claude web client, which kept answering its own voice. The
-- browser's canceller does not hold up against a phone's speaker sitting a
-- few centimetres from its microphone.
--
-- pipewire-hal.conf loads PipeWire's echo canceller (webrtc) as a sink and a
-- source of its own. Through those, the same test had no echo left. This
-- script decides who goes through them: every audio stream of a process that
-- plays and records at the same time - which is what a conversation looks
-- like from here, whatever the app calls it. Music, a podcast, a voice memo
-- stay where they are and cost nothing.
--
-- Only while furios.echo-cancel is on, and off by default: the canceller
-- costs 10-20 % of a core while a conversation runs.
--
-- What this does not touch: a stream with a target of its own (the user moved
-- it, or the app asked for a device - find-defined-target picked that before
-- this runs), the canceller's own streams, and monitor captures, which record
-- a sink rather than a microphone.

cutils = require ("common-utils")
lutils = require ("linking-utils")
log = Log.open_topic ("s-linking")

SETTING = "furios.echo-cancel"
EC_SINK = "furios-echo-cancel-sink"
EC_SOURCE = "furios-echo-cancel-source"

function enabled ()
  return Settings.get_boolean (SETTING) == true
end

-- The process a stream belongs to. Firefox opens playback and capture on two
-- connections of its own, so the client is the wrong thing to compare.
function processOf (props)
  return props ["application.process.id"] or props ["pipewire.sec.pid"]
end

-- An inner stream of a filter - the canceller's, or any other's - carries a
-- link group. Sending the canceller's playback into its own sink would be a
-- loop.
function isFilterStream (props)
  return props ["node.link-group"] ~= nil
end

function isMicCapture (props)
  return props ["media.class"] == "Stream/Input/Audio" and
         not cutils.parseBool (props ["stream.capture.sink"])
end

-- Does this process play and record right now?
function inConversation (om, pid)
  local plays, records = false, false
  for si in om:iterate { type = "SiLinkable",
                         Constraint { "item.node.type", "=", "stream" } } do
    local p = si.properties
    if processOf (p) == pid and not isFilterStream (p) then
      if p ["media.class"] == "Stream/Output/Audio" then
        plays = true
      elseif isMicCapture (p) then
        records = true
      end
    end
  end
  return plays and records
end

-- Which of the canceller's nodes a stream should go to, or nil.
function wantedTarget (om, props)
  if not enabled () then
    return nil
  end
  if props ["item.node.type"] ~= "stream" or isFilterStream (props) then
    return nil
  end
  local want
  if props ["media.class"] == "Stream/Output/Audio" then
    want = EC_SINK
  elseif isMicCapture (props) then
    want = EC_SOURCE
  else
    return nil
  end
  local pid = processOf (props)
  if not pid or not inConversation (om, pid) then
    return nil
  end
  return want
end

SimpleEventHook {
  name = "linking/furios-echo-cancel-target",
  after = "linking/find-defined-target",
  before = { "linking/find-audio-group-target",
             "linking/find-filter-target",
             "linking/find-media-role-target",
             "linking/find-media-role-sink-target",
             "linking/find-default-target",
             "linking/prepare-link" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local _, om, si, si_props, si_flags, target =
        lutils:unwrap_select_target_event (event)
    if target then
      return
    end

    local want = wantedTarget (om, si_props)
    if not want then
      return
    end

    local ec = om:lookup { type = "SiLinkable",
                           Constraint { "node.name", "=", want } }
    if not ec then
      log:info ("echo cancel: " .. want .. " is missing - " ..
                    "pipewire-hal.conf without the canceller?")
      return
    end
    if not lutils.canLink (si_props, ec) then
      return
    end
    local compatible, can_passthrough =
        lutils.checkPassthroughCompatibility (si, ec)
    if not compatible then
      return
    end

    log:info (string.format ("echo cancel: %s (%s) -> %s",
        tostring (si_props ["node.name"]), tostring (processOf (si_props)),
        want))
    si_flags.can_passthrough = can_passthrough
    event:set_data ("target", ec)
  end
}:register ()

-- A new stream only gets its own target chosen; the others of the same
-- process stay where they are. When Firefox opens the microphone, its
-- playback has been running for a while - so the whole graph is looked at
-- again, and the same when the microphone closes and the playback should go
-- back to the speaker.
SimpleEventHook {
  name = "linking/furios-echo-cancel-rescan",
  interests = {
    EventInterest {
      Constraint { "event.type", "c", "session-item-added",
                                      "session-item-removed" },
      Constraint { "event.session-item.interface", "=", "linkable" },
    },
  },
  execute = function (event)
    if not enabled () then
      return
    end
    local props = event:get_subject ().properties
    if props ["item.node.type"] ~= "stream" or isFilterStream (props) or
       not processOf (props) then
      return
    end
    event:get_source ():call ("schedule-rescan", "linking")
  end
}:register ()

-- Switched on or off: the streams that are running follow at once, both ways.
pcall (function ()
  Settings.subscribe (SETTING, function ()
    local source = Plugin.find ("standard-event-source")
    if source then
      source:call ("schedule-rescan", "linking")
    end
  end)
end)
