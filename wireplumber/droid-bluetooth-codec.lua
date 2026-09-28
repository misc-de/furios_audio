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
--                 below swaps an A2DP choice for the preferred codec before it
--                 is applied, so the headset negotiates once, not twice.
--   switching     after a call droid-bluetooth-call.lua, and audioctl after
--                 bt-mic, put the card on plain a2dp-sink - the best codec
--                 again. Any profile change is looked at and corrected.
--   the setting   changed with "audioctl bt-codec", it applies to a headset
--                 that is connected right now, without a reconnect.
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
-- setting changes or the headset connects afresh.
tried = {}

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
end

-- A card that plays music goes onto the wanted profile. "auto" only acts when
-- the setting was just changed: otherwise a profile somebody chose by hand
-- would be undone every time it changed.
function correct (card, why, even_auto)
  if not isBluez (card) then
    return
  end
  if preferredCodec (card) == nil and not even_auto then
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
  execute = function (event)
    local ok, err = pcall (function ()
      local card = event:get_subject ()
      if not isBluez (card) or preferredCodec (card) == nil then
        return
      end
      local picked = event:get_data ("selected-profile")
      if codecOf (picked) == nil then
        return
      end
      local want = wantedProfile (card)
      if want ~= nil and want.index ~= picked.index then
        tried[card["bound-id"] or 0] = nil
        log:info ("bluetooth codec: " .. want.name .. " instead of " ..
                  tostring (picked.name))
        event:set_data ("selected-profile", want)
      end
    end)
    if not ok then
      -- WirePlumber's own choice stands: music on another codec is fine,
      -- no profile at all is not.
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
      correct (event:get_subject (), "profile changed")
    end)
    if not ok then
      log:warning ("bluetooth codec: correcting failed - " .. tostring (err))
    end
  end,
}

profile_changed_hook:register ()

function applyToAll ()
  tried = {}
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
