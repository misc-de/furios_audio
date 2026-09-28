-- SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
-- SPDX-License-Identifier: MIT
-- Which codec a Bluetooth headset plays music with.
--
-- WirePlumber picks the best A2DP codec both ends know, which on this phone is
-- AAC for most headsets - and AAC is the expensive one. Measured 2026-09-12,
-- bluebinder plus wireplumber while music plays: AAC 7.2 %, SBC-XQ 7.0 %,
-- SBC 4.3 % of a core. SBC saves 40 % and sounds audibly worse than SBC-XQ;
-- SBC-XQ sounds like AAC and saves nothing. That is a choice for the owner,
-- so it is a setting, furios.bluetooth-codec, and "auto" (the default) leaves
-- WirePlumber's own choice alone.
--
-- A preference has to hold in three places, and each is its own way in:
--
--   connecting    WirePlumber selects a profile (select-profile). The hook
--                 below leaves that pick alone and asks for the preferred
--                 codec only once the headset has been quiet for SETTLE_MS.
--   switching     after a call droid-bluetooth-call.lua, and audioctl after
--                 bt-mic, put the card on plain a2dp-sink - the best codec
--                 again. Any profile change is looked at and corrected, after
--                 the same wait.
--   the setting   changed with "audioctl bt-codec", it applies to a headset
--                 that is connected right now, without a reconnect.
--
-- Why wait: swapping the pick inside select-profile made PipeWire reconfigure
-- a stream the headset was still setting up itself. Measured 2026-09-28 21:55
-- with a Soundcore Liberty 4 Pro and sbc_xq: "SET_CONFIGURATION request
-- rejected: Stream End Point in Use", BlueZ dropped A2DP, the headset had no
-- music output and everything played from the phone's speaker.
--
-- And every request is checked CHECK_MS later. A headset still on another
-- codec refused: it is not asked again until the setting changes, and one
-- left without any A2DP profile is put back on plain a2dp-sink, its own best
-- - music on another codec is fine, no music is not.
--
-- Only ever from one A2DP profile to another. A headset on hands-free is in a
-- call or recording, and that is not this script's to touch. Never stored
-- (save = false): the preference is the setting, and a stored profile would
-- outlive it once it is set back to auto.

cutils = require ("common-utils")
log = Log.open_topic ("s-device")

SETTING = "furios.bluetooth-codec"
-- Per headset, overriding the one above: "F4:9D:8A:00:00:01=sbc_xq;..." -
-- a plain string, because that is what wpctl and every WirePlumber version
-- here can store and read back. "auto" for one headset means WirePlumber's
-- best for that one, whatever the setting above says.
DEVICE_SETTING = "furios.bluetooth-codec-devices"

-- What was last asked of each card, so a headset that refuses a codec (the
-- profile comes straight back) is not asked again and again. Cleared when the
-- setting changes.
tried = {}

-- Headsets that refused a codec, by address: the codec they refused. Kept
-- across reconnects - a refusal is the headset's, not the connection's - and
-- cleared when the setting changes.
refused = {}

-- A pending correction per card, so a burst of profile changes while a
-- headset connects ends in one request, SETTLE_MS after the last of them.
pending = {}

SETTLE_MS = 8000
CHECK_MS = 6000

-- The codec an A2DP profile carries, or nil for anything else.
--
-- From the description, not the name: libspa-bluez5 names the per-codec
-- profiles "a2dp-sink-<codec>" but keeps plain "a2dp-sink" for the best one,
-- and only the description says which that is - "High Fidelity Playback
-- (A2DP Sink, codec AAC)". Lowered, with spaces and dashes as underscores,
-- the description's spelling is the codec's own name: SBC-XQ is sbc_xq,
-- aptX HD is aptx_hd.
function codecOf (profile)
  local name = profile and profile.name or ""
  if name:sub (1, 9) ~= "a2dp-sink" then
    return nil
  end
  local codec = (profile.description or ""):match ("codec ([^%)]+)%)")
  if codec then
    return (codec:lower ():gsub ("[%s%-]", "_"))
  end
  return name:match ("^a2dp%-sink%-(.+)$")
end

function readSetting (name)
  local ok, value = pcall (function ()
    return Settings.get_string (name)
  end)
  if not ok or type (value) ~= "string" then
    return nil
  end
  return (value:gsub ('"', ""))
end

-- What was chosen for this headset alone, or nil.
function deviceChoice (card)
  local addr = card and card.properties and card.properties["api.bluez5.address"]
  local map = readSetting (DEVICE_SETTING)
  if not addr or not map then
    return nil
  end
  addr = addr:upper ()
  for a, codec in map:gmatch ("([%x:]+)=([%w_]+)") do
    if a:upper () == addr then
      return codec
    end
  end
  return nil
end

-- The preferred codec for a card, or nil for "leave it to WirePlumber". An
-- older WirePlumber, a missing schema entry, anything unexpected: all of that
-- is nil, which is the behaviour without this script.
function preferredCodec (card)
  local value = deviceChoice (card)
  if value == nil then
    value = readSetting (SETTING)
  end
  if value == nil or value == "" or value == "auto" then
    return nil
  end
  return value
end

function isBluez (card)
  return card ~= nil and card.properties["device.api"] == "bluez5"
end

function activeProfile (card)
  for p in card:iterate_params ("Profile") do
    local profile = cutils.parseParam (p, "Profile")
    if profile then
      return profile
    end
  end
  return nil
end

-- The profile to be on for this card: the one carrying the preferred codec,
-- or for "auto" plain a2dp-sink, WirePlumber's best. nil when the headset
-- does not offer the codec - then it stays where it is.
function wantedProfile (card)
  local codec = preferredCodec (card)
  for p in card:iterate_params ("EnumProfile") do
    local profile = cutils.parseParam (p, "EnumProfile")
    if profile and profile.available ~= "no" then
      if codec == nil and profile.name == "a2dp-sink" then
        return profile
      elseif codec ~= nil and codecOf (profile) == codec then
        return profile
      end
    end
  end
  return nil
end

function addressOf (card)
  local addr = card and card.properties and card.properties["api.bluez5.address"]
  return addr and addr:upper () or nil
end

-- Did the headset take what was asked? Its active profile tells. On anything
-- else the refusal is remembered, and a headset left with no A2DP profile at
-- all gets its own best back.
function checkOutcome (card, want, codec)
  local active = activeProfile (card)
  if active ~= nil and active.index == want.index then
    log:info ("bluetooth codec: the headset plays " .. codec)
    return
  end
  local addr = addressOf (card)
  if addr then
    refused[addr] = codec
  end
  local now = active and active.name or "no profile"
  log:warning ("bluetooth codec: the headset did not take " .. codec ..
               " (now " .. now .. ") - not asking again")
  if active ~= nil and codecOf (active) ~= nil then
    return
  end
  if active ~= nil and active.name ~= "off" then
    return    -- hands-free: a call or a recording, not ours
  end
  for p in card:iterate_params ("EnumProfile") do
    local profile = cutils.parseParam (p, "EnumProfile")
    if profile and profile.name == "a2dp-sink" and profile.available ~= "no" then
      log:warning ("bluetooth codec: putting the headset back on its own " ..
                   "best, " .. tostring (codecOf (profile)))
      card:set_params ("Profile", Pod.Object {
        "Spa:Pod:Object:Param:Profile", "Profile",
        index = profile.index,
        save = false,
      })
      return
    end
  end
end

function setProfile (card, profile, why)
  local id = card["bound-id"] or 0
  if tried[id] == profile.index then
    return
  end
  tried[id] = profile.index
  log:info ("bluetooth codec: " .. why .. " - putting the headset on " ..
            profile.name)
  card:set_params ("Profile", Pod.Object {
    "Spa:Pod:Object:Param:Profile", "Profile",
    index = profile.index,
    save = false,
  })
  local codec = codecOf (profile) or profile.name
  Core.timeout_add (CHECK_MS, function ()
    local ok, err = pcall (checkOutcome, card, profile, codec)
    if not ok then
      log:warning ("bluetooth codec: checking failed - " .. tostring (err))
    end
    return false
  end)
end

-- A card that plays music goes onto the wanted profile. "auto" only acts when
-- the setting was just changed: otherwise a profile somebody chose by hand
-- would be undone every time it changed.
function correct (card, why, even_auto)
  if not isBluez (card) then
    return
  end
  local codec = preferredCodec (card)
  if codec == nil and not even_auto then
    return
  end
  if codec ~= nil and refused[addressOf (card) or ""] == codec then
    return
  end
  local active = activeProfile (card)
  if active == nil or codecOf (active) == nil then
    return
  end
  local want = wantedProfile (card)
  if want == nil or want.index == active.index then
    return
  end
  setProfile (card, want, why)
end

-- Correct this card once it has been quiet for SETTLE_MS. Each call starts
-- the wait again, so only the last of a burst acts.
function later (card, why)
  local id = card["bound-id"] or 0
  local mine = (pending[id] or 0) + 1
  pending[id] = mine
  Core.timeout_add (SETTLE_MS, function ()
    if pending[id] ~= mine then
      return false
    end
    pending[id] = nil
    local ok, err = pcall (correct, card, why)
    if not ok then
      log:warning ("bluetooth codec: correcting failed - " .. tostring (err))
    end
    return false
  end)
end

preferred_codec_hook = SimpleEventHook {
  name = "device/furios-preferred-codec",
  after = { "device/find-stored-profile", "device/find-preferred-profile",
            "device/find-best-profile" },
  -- Before the call's own hook, which has the last word while a call is on
  -- the headset.
  before = { "device/furios-keep-call-profile", "device/apply-profile" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-profile" },
    },
  },
  -- WirePlumber's pick stands; the preferred codec follows once the headset
  -- is quiet (see the top of this file).
  execute = function (event)
    local ok, err = pcall (function ()
      local card = event:get_subject ()
      if not isBluez (card) or preferredCodec (card) == nil then
        return
      end
      if codecOf (event:get_data ("selected-profile")) == nil then
        return
      end
      later (card, "connected")
    end)
    if not ok then
      log:warning ("bluetooth codec: choosing failed - " .. tostring (err))
    end
  end,
}

preferred_codec_hook:register ()

profile_changed_hook = SimpleEventHook {
  name = "device/furios-correct-codec",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "event.subject.param-id", "=", "Profile" },
    },
  },
  execute = function (event)
    local ok, err = pcall (function ()
      local card = event:get_subject ()
      if isBluez (card) then
        later (card, "profile changed")
      end
    end)
    if not ok then
      log:warning ("bluetooth codec: correcting failed - " .. tostring (err))
    end
  end,
}

profile_changed_hook:register ()

function applyToAll ()
  tried = {}
  refused = {}
  local om = cutils.get_object_manager ("device")
  for card in om:iterate { Constraint { "device.api", "=", "bluez5" } } do
    correct (card, "setting changed", true)
  end
end

-- An older WirePlumber without subscribe still gets the other two ways in.
for _, name in ipairs ({ SETTING, DEVICE_SETTING }) do
  pcall (function ()
    Settings.subscribe (name, function ()
      local ok, err = pcall (applyToAll)
      if not ok then
        log:warning ("bluetooth codec: applying the setting failed - " ..
                     tostring (err))
      end
    end)
  end)
end
