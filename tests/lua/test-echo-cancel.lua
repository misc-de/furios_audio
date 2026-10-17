-- SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
-- SPDX-License-Identifier: MIT
-- Which streams go through the echo canceller: those of an app in a
-- conversation, and nothing else.
local T = dofile((os.getenv("TEST_ROOT") or ".") .. "/tests/lua/harness.lua")
local wp = T.wp

T.suite("echo cancel")

-- The session items a select-target event sees, as a tiny object manager.
-- Constraints are equality only, like the rest of the stub.
local items

local function si(props)
  local s = { properties = props }
  table.insert(items, s)
  return s
end

local function matches(obj, constraints)
  for _, c in ipairs(constraints) do
    if type(c) == "table" and c[2] == "=" and
       tostring(obj.properties[c[1]]) ~= tostring(c[3]) then
      return false
    end
  end
  return true
end

local om = {
  iterate = function (_, constraints)
    local i = 0
    return function ()
      while true do
        i = i + 1
        local s = items[i]
        if s == nil then return nil end
        if matches(s, constraints) then return s end
      end
    end
  end,
  lookup = function (_, constraints)
    for _, s in ipairs(items) do
      if matches(s, constraints) then return s end
    end
  end,
}

local can_link, compatible, rescans

local function setup(on)
  wp.install()
  items = {}
  can_link, compatible, rescans = true, true, 0
  package.loaded["linking-utils"] = {
    unwrap_select_target_event = function (_, event)
      return nil, om, event.si, event.si.properties, event.flags, event.data.target
    end,
    canLink = function () return can_link end,
    checkPassthroughCompatibility = function () return compatible, false end,
  }
  local source = { call = function (_, method, what)
    if method == "schedule-rescan" and what == "linking" then
      rescans = rescans + 1
    end
  end }
  Plugin = { find = function (name)
    if name == "standard-event-source" then return source end
  end }
  wp.settings["furios.echo-cancel"] = on
  T.load_script(T.root .. "/wireplumber/droid-echo-cancel.lua")
  return source
end

local function stream(class, pid, extra)
  local p = { ["item.node.type"] = "stream", ["media.class"] = class,
              ["application.process.id"] = pid, ["node.name"] = class .. tostring(pid) }
  for k, v in pairs(extra or {}) do p[k] = v end
  return si(p)
end

local function play(pid, extra) return stream("Stream/Output/Audio", pid, extra) end
local function record(pid, extra) return stream("Stream/Input/Audio", pid, extra) end

local function canceller()
  local sink = si({ ["node.name"] = "furios-echo-cancel-sink", ["item.node.type"] = "device" })
  local source = si({ ["node.name"] = "furios-echo-cancel-source", ["item.node.type"] = "device" })
  return sink, source
end

-- The target the hook picks for a stream, or nil.
local function pick(s, already)
  local event = { si = s, flags = {}, data = { target = already } }
  event.set_data = function (self, key, value) self.data[key] = value end
  T.traced(function ()
    wp.hooks["linking/furios-echo-cancel-target"].execute(event)
  end)
  return event.data.target
end

local function name_of(target)
  return target and target.properties["node.name"]
end

-- --- a conversation goes through it, both ways ----------------------------

setup(true)
local sink, source = canceller()
local out, mic = play(42), record(42)
T.check_equal("an app that plays and records sends its playback through it",
              "furios-echo-cancel-sink", name_of(pick(out)))
T.check_equal("and its microphone", "furios-echo-cancel-source", name_of(pick(mic)))

-- --- everything else stays where it is ------------------------------------

setup(true)
canceller()
T.check_equal("music alone is left alone", nil, pick(play(7)))
setup(true)
canceller()
T.check_equal("a voice memo alone is left alone", nil, pick(record(8)))

-- Two apps, one playing, one recording: not a conversation.
setup(true)
canceller()
local music = play(7)
record(8)
T.check_equal("one app playing and another recording is not a conversation",
              nil, pick(music))

-- A level meter records a sink, not a microphone.
setup(true)
canceller()
local o = play(9)
local meter = record(9, { ["stream.capture.sink"] = "true" })
T.check_equal("a monitor capture does not make a conversation", nil, pick(o))
T.check_equal("and is never sent through the canceller itself", nil, pick(meter))

-- The canceller's own inner streams: its playback into its own sink would be
-- a loop.
setup(true)
canceller()
local inner = play(1, { ["node.link-group"] = "echo-cancel-1" })
record(1, { ["node.link-group"] = "echo-cancel-1" })
T.check_equal("a filter's inner stream is never touched", nil, pick(inner))

-- A target somebody chose wins.
setup(true)
canceller()
local chosen = play(42)
record(42)
local mine = { properties = { ["node.name"] = "bluez_output.x" } }
T.check("a stream with a target of its own keeps it", pick(chosen, mine) == mine)

setup(true)
canceller()
local nopid = stream("Stream/Output/Audio", nil)
T.check_equal("a stream without a process is left alone", nil, pick(nopid))

setup(true)
canceller()
local video = stream("Stream/Output/Video", 42)
record(42)
T.check_equal("only audio", nil, pick(video))

setup(true)
canceller()
local node = play(42, { ["item.node.type"] = "device" })
record(42)
T.check_equal("only streams, not devices", nil, pick(node))

-- --- switched off, or nothing to go to ------------------------------------

setup(false)
canceller()
local off_out = play(42)
record(42)
T.check_equal("switched off nothing goes through it", nil, pick(off_out))

setup(nil)
canceller()
local unset = play(42)
record(42)
T.check_equal("and a setting nobody knows counts as off", nil, pick(unset))

setup(true)
local orphan = play(42)
record(42)
T.check_equal("without the canceller's nodes the default stays", nil, pick(orphan))
T.check("and the log says why", (function ()
  for _, c in ipairs(wp.calls_of("log")) do
    if tostring(c.args[2]):find("is missing", 1, true) then return true end
  end
  return false
end)())

setup(true)
canceller()
local refused = play(42)
record(42)
can_link = false
T.check_equal("a link WirePlumber refuses is not forced", nil, pick(refused))
can_link, compatible = true, false
T.check_equal("nor one of an incompatible format", nil, pick(refused))

-- --- the rest of the graph follows ----------------------------------------

local function item_event(props)
  local src = Plugin.find("standard-event-source")
  T.traced(function ()
    wp.hooks["linking/furios-echo-cancel-rescan"].execute({
      get_subject = function () return { properties = props } end,
      get_source = function () return src end,
    })
  end)
end

setup(true)
item_event({ ["item.node.type"] = "stream", ["application.process.id"] = 42 })
T.check_equal("a stream coming or going looks at the others again", 1, rescans)
item_event({ ["item.node.type"] = "device" })
item_event({ ["item.node.type"] = "stream", ["node.link-group"] = "x",
             ["application.process.id"] = 1 })
item_event({ ["item.node.type"] = "stream" })
T.check_equal("devices, inner streams and streams without a process do not", 1, rescans)

setup(false)
item_event({ ["item.node.type"] = "stream", ["application.process.id"] = 42 })
T.check_equal("switched off it never rescans", 0, rescans)

setup(true)
T.traced(function () wp.subscribers["furios.echo-cancel"]() end)
T.check_equal("switching it moves the running streams at once", 1, rescans)
Plugin = { find = function () return nil end }
T.traced(function () wp.subscribers["furios.echo-cancel"]() end)
T.check_equal("and without an event source it does not fail", 1, rescans)

-- The pid as PipeWire sets it, when the client did not say.
setup(true)
canceller()
local a = si({ ["item.node.type"] = "stream", ["media.class"] = "Stream/Output/Audio",
               ["pipewire.sec.pid"] = 55 })
si({ ["item.node.type"] = "stream", ["media.class"] = "Stream/Input/Audio",
     ["pipewire.sec.pid"] = 55 })
T.check_equal("the process is also found by pipewire.sec.pid",
              "furios-echo-cancel-sink", name_of(pick(a)))

T.done()
