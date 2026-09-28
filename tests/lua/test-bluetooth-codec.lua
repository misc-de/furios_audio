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

setup("sbc")
local card = wp.add("device", bt_card())
T.check_equal("connecting picks the preferred codec", "a2dp-sink-sbc",
              select_profile(card, AAC).name)
T.check_equal("a hands-free pick is left alone", "headset-head-unit",
              select_profile(card, HFP).name)

setup("auto")
card = wp.add("device", bt_card())
T.check_equal("auto leaves WirePlumber's pick", "a2dp-sink",
              select_profile(card, AAC).name)

setup(nil)
card = wp.add("device", bt_card())
T.check_equal("no setting at all is auto", "a2dp-sink",
              select_profile(card, AAC).name)

setup("ldac")
card = wp.add("device", bt_card())
T.check_equal("a codec the headset lacks leaves the pick", "a2dp-sink",
              select_profile(card, AAC).name)

setup("sbc")
card = wp.add("device", bt_card())
card.iterate_params = function () error("the card went away") end
T.check_equal("an error leaves WirePlumber's pick", "a2dp-sink",
              select_profile(card, AAC).name)

-- --- switching back after a call ---------------------------------------------

setup("sbc_xq")
card = wp.add("device", bt_card(AAC))
profile_changed(card)
T.check_equal("back on plain a2dp-sink after a call, it is corrected",
              "3", table.concat(profiles_set(), ","))

setup("sbc_xq")
card = wp.add("device", bt_card(SBC_XQ))
profile_changed(card)
T.check_equal("already on it: nothing", "", table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(HFP))
profile_changed(card)
T.check_equal("in hands-free (a call, a recording): nothing", "",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", bt_card(AAC))
profile_changed(card)
profile_changed(card)   -- the headset refused and came back to AAC
T.check_equal("a codec the headset refuses is asked for once", "2",
              table.concat(profiles_set(), ","))

setup("auto")
card = wp.add("device", bt_card(SBC))
profile_changed(card)
T.check_equal("auto does not undo a profile chosen by hand", "",
              table.concat(profiles_set(), ","))

setup("sbc")
card = wp.add("device", wp.object({ ["device.api"] = "droid-hal" },
                                  { params = { Profile = { AAC } } }))
profile_changed(card)
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
T.check_equal("a headset's own choice wins over auto, address in any case",
              "a2dp-sink-sbc_xq", select_profile(card, AAC).name)
card = wp.add("device", bt_card(nil, "11:22:33:44:55:66"))
T.check_equal("a headset without one follows the setting for all",
              "a2dp-sink", select_profile(card, AAC).name)

setup("sbc")
wp.settings["furios.bluetooth-codec-devices"] = "F4:9D:8A:00:00:01=auto"
card = wp.add("device", bt_card())
T.check_equal("auto for one headset means WirePlumber's best for it",
              "a2dp-sink", select_profile(card, AAC).name)

setup("sbc")
wp.settings["furios.bluetooth-codec-devices"] = "not a list at all"
card = wp.add("device", bt_card())
T.check_equal("an unreadable list falls back to the setting for all",
              "a2dp-sink-sbc", select_profile(card, AAC).name)

setup("auto")
card = wp.add("device", bt_card(AAC))
wp.settings["furios.bluetooth-codec-devices"] = "F4:9D:8A:00:00:01=sbc"
T.traced(function () wp.subscribers["furios.bluetooth-codec-devices"]() end)
T.check_equal("a new choice for a connected headset applies at once", "2",
              table.concat(profiles_set(), ","))

T.done()
