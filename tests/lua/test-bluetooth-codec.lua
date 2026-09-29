-- SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
-- SPDX-License-Identifier: MIT
-- The A2DP codec the owner chose, held on connect, after a call and on change.
local T = dofile((os.getenv("TEST_ROOT") or ".") .. "/tests/lua/harness.lua")
local wp = T.wp

T.suite("bluetooth codec")

-- A headset as PipeWire publishes one on this phone: plain a2dp-sink is the
-- best codec both ends know (AAC here), the others carry their name - and the
-- description is the only place that says what the plain one is.
local AAC    = { name = "a2dp-sink", index = 1,
                 description = "High Fidelity Playback (A2DP Sink, codec AAC)" }
local SBC    = { name = "a2dp-sink-sbc", index = 2,
                 description = "High Fidelity Playback (A2DP Sink, codec SBC)" }
local SBC_XQ = { name = "a2dp-sink-sbc_xq", index = 3,
                 description = "High Fidelity Playback (A2DP Sink, codec SBC-XQ)" }
local HFP    = { name = "headset-head-unit", index = 4,
                 description = "Headset Head Unit (HSP/HFP, codec mSBC)" }

local function bt_card(active, addr)
  return wp.object({ ["device.api"] = "bluez5", ["bound-id"] = 7,
                     ["api.bluez5.address"] = addr or "F4:9D:8A:00:00:01" }, { params = {
    EnumProfile = { AAC, SBC, SBC_XQ, HFP },
    Profile = { active or AAC },
  } })
end

local function setup(codec)
  wp.install()
  wp.settings["furios.bluetooth-codec"] = codec
  T.load_script(T.root .. "/wireplumber/droid-bluetooth-codec.lua")
end

local function select_profile(card, picked)
  local data = { ["selected-profile"] = picked }
  local event = {
    get_subject = function () return card end,
    get_data = function (_, key) return data[key] end,
    set_data = function (_, key, value) data[key] = value end,
  }
  T.traced(function () wp.hooks["device/furios-preferred-codec"].execute(event) end)
  return data["selected-profile"]
end

local function profile_changed(card)
  T.traced(function ()
    wp.hooks["device/furios-correct-codec"].execute({
      get_subject = function () return card end })
  end)
end

-- The profile indexes the script asked for, in order.
local function profiles_set()
  local out = {}
  for _, c in ipairs(wp.calls_of("set_params")) do
    if c.args[2] == "Profile" then
      table.insert(out, c.args[3].body.index)
      T.check("never stored", c.args[3].body.save == false)
    end
  end
  return out
end

-- --- the name of a codec ---------------------------------------------------

setup("sbc")
T.check_equal("plain a2dp-sink is what its description says", "aac", codecOf(AAC))
T.check_equal("SBC-XQ is sbc_xq", "sbc_xq", codecOf(SBC_XQ))
T.check_equal("aptX HD is aptx_hd", "aptx_hd", codecOf({ name = "a2dp-sink-aptx_hd",
  description = "High Fidelity Playback (A2DP Sink, codec aptX HD)" }))
T.check_equal("without a description the name suffix", "ldac",
              codecOf({ name = "a2dp-sink-ldac" }))
T.check("hands-free is no A2DP codec", codecOf(HFP) == nil)

-- --- connecting --------------------------------------------------------------

-- Run whatever the script is waiting for, and what that schedules in turn.
local function wait()
  T.traced(function ()
    while wp.fire_timers() > 0 do end
  end)
end

local function asked()
  return table.concat(profiles_set(), ",")
end

setup("sbc")
local card = wp.add("device", bt_card())
T.check_equal("connecting leaves WirePlumber's pick", "a2dp-sink",
              select_profile(card, AAC).name)
T.check_equal("nothing is asked while the headset connects", "", asked())
T.check_equal("it waits SETTLE_MS", SETTLE_MS, wp.calls_of("timeout_add")[1].args[1])
wait()
T.check_equal("once quiet, the preferred codec is asked for", "2", asked())

setup("sbc")
card = wp.add("device", bt_card())
select_profile(card, AAC)
profile_changed(card)
profile_changed(card)
wait()
T.check_equal("a burst of changes while connecting asks once", "2", asked())

setup("sbc")
card = wp.add("device", bt_card(HFP))
T.check_equal("a hands-free pick is left alone", "headset-head-unit",
              select_profile(card, HFP).name)
wait()
T.check_equal("and nothing is asked later", "", asked())

setup("auto")
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("auto asks for nothing", "", asked())

setup(nil)
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("no setting at all is auto", "", asked())

setup("ldac")
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("a codec the headset lacks is not asked for", "", asked())

setup("sbc")
card = wp.add("device", bt_card())
card.iterate_params = function () error("the card went away") end
T.check_equal("an error leaves WirePlumber's pick", "a2dp-sink",
              select_profile(card, AAC).name)
wait()
T.check_equal("and a card gone by then is left alone", "", asked())

-- --- the headset says no -------------------------------------------------------

-- 2026-09-28 21:55: the Liberty 4 Pro rejected SBC-XQ ("Stream End Point in
-- Use"), BlueZ dropped A2DP and the card was left without music.
setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
T.traced(function () wp.fire_timers() end)        -- the wait: asks
card.params.Profile = { { name = "off", index = 0, description = "Off" } }
T.traced(function () wp.fire_timers() end)        -- the check
T.check_equal("a headset left without music gets its own best back", "3,1",
              asked())

setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()                                            -- stays on AAC: refused
T.check_equal("refused but still playing: left on its codec", "3", asked())
wp.objects.device = {}                            -- it disconnects
local again = wp.add("device", wp.object({ ["device.api"] = "bluez5", ["bound-id"] = 8,
  ["api.bluez5.address"] = "f4:9d:8a:00:00:01" }, { params = {
  EnumProfile = { AAC, SBC, SBC_XQ, HFP }, Profile = { AAC } } }))
select_profile(again, AAC)
wait()
T.check_equal("reconnected, the refusing headset is not asked again", "3", asked())
wp.settings["furios.bluetooth-codec"] = "sbc"
T.traced(function () wp.subscribers["furios.bluetooth-codec"]() end)
T.check_equal("a changed setting may ask it again", "3,2", asked())

setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
T.traced(function () wp.fire_timers() end)
card.params.Profile = { SBC_XQ }                  -- took it
wait()
T.check_equal("a headset that took the codec is left there", "3", asked())
select_profile(card, SBC_XQ)
wait()
T.check_equal("and not asked again", "3", asked())

setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
T.traced(function () wp.fire_timers() end)
card.params.Profile = { HFP }                     -- a call came in meanwhile
wait()
T.check_equal("hands-free by the time of the check is not touched", "3", asked())

-- 2026-09-29 06:34: the headset went into its case and came out again, and
-- PipeWire gave the new card the same id. The request from before was still
-- on record for that id, so nothing was asked and it stayed on AAC.
setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
T.traced(function () wp.fire_timers() end)
card.params.Profile = { SBC_XQ }
wait()
wp.objects.device = {}                            -- into the case
card = wp.add("device", bt_card())                -- out again, same id 7
select_profile(card, AAC)
wait()
T.check_equal("a card back under the same id is asked again", "3,3", asked())

setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
wp.objects.device = {}                            -- gone before the wait ends
wait()
T.check_equal("a card gone before the wait ends is left alone", "", asked())

setup("sbc_xq")
card = wp.add("device", bt_card())
select_profile(card, AAC)
T.traced(function () wp.fire_timers() end)
wp.objects.device = {}                            -- gone before the check
wait()
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("leaving before the check is no refusal", "3,3", asked())

-- --- switching back after a call ---------------------------------------------

setup("sbc_xq")
card = wp.add("device", bt_card(AAC))
profile_changed(card)
wait()
T.check_equal("back on plain a2dp-sink after a call, it is corrected",
              "3", table.concat(profiles_set(), ","))

setup("sbc_xq")
card = wp.add("device", bt_card(SBC_XQ))
profile_changed(card)
wait()
T.check_equal("already on it: nothing", "", table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(HFP))
profile_changed(card)
wait()
T.check_equal("in hands-free (a call, a recording): nothing", "",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(AAC))
profile_changed(card)
T.traced(function () wp.fire_timers() end)
profile_changed(card)   -- the headset refused and came back to AAC
wait()
T.check_equal("a codec the headset refuses is asked for once", "2",
              table.concat(profiles_set(), ","))

setup("auto")
card = wp.add("device", bt_card(SBC))
profile_changed(card)
wait()
T.check_equal("auto does not undo a profile chosen by hand", "",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", wp.object({ ["device.api"] = "droid-hal" },
                                  { params = { Profile = { AAC } } }))
profile_changed(card)
wait()
T.check_equal("the phone's own card is not touched", "",
              table.concat(profiles_set(), ","))

-- --- the setting changes -------------------------------------------------------

setup("auto")
card = wp.add("device", bt_card(AAC))
wp.settings["furios.bluetooth-codec"] = "sbc"
T.traced(function () wp.subscribers["furios.bluetooth-codec"]() end)
T.check_equal("a new preference reaches a connected headset", "2",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(SBC))
wp.settings["furios.bluetooth-codec"] = "auto"
T.traced(function () wp.subscribers["furios.bluetooth-codec"]() end)
T.check_equal("back to auto puts it on WirePlumber's best", "1",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(AAC))
profile_changed(card)
T.traced(function () wp.fire_timers() end)
card.params.Profile = { AAC }            -- refused
wp.settings["furios.bluetooth-codec"] = "sbc_xq"
T.traced(function () wp.subscribers["furios.bluetooth-codec"]() end)
wp.settings["furios.bluetooth-codec"] = "sbc"
T.traced(function () wp.subscribers["furios.bluetooth-codec"]() end)
T.check_equal("a changed setting may ask again", "2,3,2",
              table.concat(profiles_set(), ","))

-- --- one headset, its own codec ------------------------------------------------

setup("auto")
wp.settings["furios.bluetooth-codec-devices"] = "98:52:3D:00:00:02=aac;f4:9d:8a:00:00:01=sbc_xq"
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("a headset's own choice wins over auto, address in any case",
              "3", asked())
card = wp.add("device", bt_card(nil, "11:22:33:44:55:66"))
select_profile(card, AAC)
wait()
T.check_equal("a headset without one follows the setting for all", "3", asked())

setup("sbc")
wp.settings["furios.bluetooth-codec-devices"] = "F4:9D:8A:00:00:01=auto"
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("auto for one headset means WirePlumber's best for it", "", asked())

setup("sbc")
wp.settings["furios.bluetooth-codec-devices"] = "not a list at all"
card = wp.add("device", bt_card())
select_profile(card, AAC)
wait()
T.check_equal("an unreadable list falls back to the setting for all", "2", asked())

setup("auto")
card = wp.add("device", bt_card(AAC))
wp.settings["furios.bluetooth-codec-devices"] = "F4:9D:8A:00:00:01=sbc"
T.traced(function () wp.subscribers["furios.bluetooth-codec-devices"]() end)
T.check_equal("a new choice for a connected headset applies at once", "2",
              table.concat(profiles_set(), ","))

T.done()
