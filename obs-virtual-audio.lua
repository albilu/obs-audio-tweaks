obs = obslua

-- VERSION 2.0: avoids the unsupported Lua monitoring-device enumeration callback.

-- ============================================================================
-- OBS PipeWire Virtual Audio Router
--
-- Creates (if missing):
--   ~/.config/pipewire/pipewire-pulse.conf.d/obs-virtual-audio.conf
--
-- Provides:
--   OBS monitoring output
--       -> OBS_Virtual_Output_Audio_As_Mic_For_Apps
--       -> .monitor
--       -> OBS_Virtual_Output_Audio_As_Mic_For_Chrome
--
-- Optional local monitoring:
--   OBS_Virtual_Output_Audio_As_Mic_For_Apps:monitor_FL/FR
--       -> selected PipeWire playback device:playback_FL/FR
-- ============================================================================

local VIRTUAL_SINK =
    "OBS_Virtual_Output_Audio_As_Mic_For_Apps"

local VIRTUAL_MIC =
    "OBS_Virtual_Output_Audio_As_Mic_For_Chrome"

local CONFIG_RELATIVE =
    "/.config/pipewire/pipewire-pulse.conf.d/obs-virtual-audio.conf"

local CONFIG_DIR_RELATIVE =
    "/.config/pipewire/pipewire-pulse.conf.d"

local SOURCE_FL = VIRTUAL_SINK .. ":monitor_FL"
local SOURCE_FR = VIRTUAL_SINK .. ":monitor_FR"

local monitor_enabled = false
local selected_device = ""
local auto_set_obs_monitor = true
local linked_device = ""

local bootstrap_done = false


local function log_info(message)
    obs.script_log(obs.LOG_INFO, "[PipeWire Audio Router] " .. message)
end

local function log_warn(message)
    obs.script_log(obs.LOG_WARNING, "[PipeWire Audio Router] " .. message)
end

local function log_error(message)
    obs.script_log(obs.LOG_ERROR, "[PipeWire Audio Router] " .. message)
end


-- ----------------------------------------------------------------------------
-- Shell helpers
-- ----------------------------------------------------------------------------

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_output(command)
    local pipe = io.popen(command .. " 2>/dev/null")
    if not pipe then
        return nil
    end

    local output = pipe:read("*a")
    pipe:close()
    return output
end

local function command_ok(command)
    local a, b, c = os.execute(command .. " >/dev/null 2>&1")

    -- LuaJIT/Lua 5.1 commonly returns a numeric status.
    if type(a) == "number" then
        return a == 0
    end

    -- Lua 5.2+ commonly returns true, "exit", 0.
    if type(a) == "boolean" then
        return a and (c == nil or c == 0)
    end

    return false
end

local function command_exists(command)
    local output = command_output("command -v " .. shell_quote(command))
    return output ~= nil and output:match("%S") ~= nil
end


-- ----------------------------------------------------------------------------
-- PipeWire persistent config
-- ----------------------------------------------------------------------------

local function config_path()
    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end
    return home .. CONFIG_RELATIVE
end

local function config_dir()
    local home = os.getenv("HOME")
    if not home or home == "" then
        return nil
    end
    return home .. CONFIG_DIR_RELATIVE
end

local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local PIPEWIRE_CONFIG = [[pulse.cmd = [
    {
        cmd = "load-module"
        args = "module-null-sink sink_name=OBS_Virtual_Output_Audio_As_Mic_For_Apps sink_properties=device.description=OBS_Virtual_Output_Audio_As_Mic_For_Apps"
        flags = [ ]
    }

    {
        cmd = "load-module"
        args = "module-remap-source master=OBS_Virtual_Output_Audio_As_Mic_For_Apps.monitor source_name=OBS_Virtual_Output_Audio_As_Mic_For_Chrome source_properties=device.description=OBS_Virtual_Output_Audio_As_Mic_For_Chrome"
        flags = [ ]
    }
]
]]

local function ensure_config_file()
    local path = config_path()
    local dir = config_dir()

    if not path or not dir then
        log_error("$HOME is not available; cannot create PipeWire config.")
        return false
    end

    if file_exists(path) then
        return true
    end

    if not command_ok("mkdir -p " .. shell_quote(dir)) then
        log_error("Could not create directory: " .. dir)
        return false
    end

    local file, err = io.open(path, "w")
    if not file then
        log_error("Could not create " .. path .. ": " .. tostring(err))
        return false
    end

    file:write(PIPEWIRE_CONFIG)
    file:close()

    return true
end


-- ----------------------------------------------------------------------------
-- Pulse/PipeWire virtual devices
--
-- The persistent config is for future pipewire-pulse starts.
-- These checks also load the modules into the CURRENT session if necessary,
-- so OBS does not have to restart PipeWire.
-- ----------------------------------------------------------------------------

local function pactl_has_named_device(kind, wanted_name)
    local output = command_output("pactl list short " .. kind)
    if not output then
        return false
    end

    for line in output:gmatch("[^\r\n]+") do
        -- pactl short format starts with:
        -- INDEX <whitespace> NAME <whitespace> ...
        local name = line:match("^%s*%d+%s+(%S+)")
        if name == wanted_name then
            return true
        end
    end

    return false
end

local function ensure_virtual_devices()
    if not command_exists("pactl") then
        log_error("'pactl' was not found. Install/enable PipeWire PulseAudio compatibility.")
        return false
    end

    local sink_ok = pactl_has_named_device("sinks", VIRTUAL_SINK)

    if not sink_ok then
        local command =
            "pactl load-module module-null-sink " ..
            "sink_name=" .. VIRTUAL_SINK .. " " ..
            "sink_properties=device.description=" .. VIRTUAL_SINK

        local output = command_output(command)

        if not output or not output:match("%d+") then
            log_error("Could not create current-session virtual sink: " .. VIRTUAL_SINK)
            return false
        end

    end

    local mic_ok = pactl_has_named_device("sources", VIRTUAL_MIC)

    if not mic_ok then
        local command =
            "pactl load-module module-remap-source " ..
            "master=" .. VIRTUAL_SINK .. ".monitor " ..
            "source_name=" .. VIRTUAL_MIC .. " " ..
            "source_properties=device.description=" .. VIRTUAL_MIC

        local output = command_output(command)

        if not output or not output:match("%d+") then
            log_error("Could not create current-session Chrome virtual mic: " .. VIRTUAL_MIC)
            return false
        end

    end

    return true
end


-- ----------------------------------------------------------------------------
-- OBS monitoring device
-- ----------------------------------------------------------------------------

local function set_obs_monitoring_device_from_checkbox()
    if not obs.obs_audio_monitoring_available() then
        log_warn("OBS reports that audio monitoring is not available.")
        return false
    end

    -- This checkbox directly owns:
    --   Settings -> Audio -> Advanced -> Monitoring Device
    --
    -- Checked:
    --   name = OBS_Virtual_Output_Audio_As_Mic_For_Apps
    --   id   = OBS_Virtual_Output_Audio_As_Mic_For_Apps
    --
    -- Unchecked:
    --   name = Default
    --   id   = default
    local target_name
    local target_id

    if auto_set_obs_monitor then
        target_name = VIRTUAL_SINK
        target_id = VIRTUAL_SINK
    else
        target_name = "Default"
        target_id = "default"
    end

    -- OBS's own Settings dialog persists these exact profile keys.
    -- Update them as well as libobs's live monitoring device so that:
    --   1. the change takes effect immediately;
    --   2. reopening Settings shows the same choice;
    --   3. the choice survives an OBS restart.
    local profile_config = nil

    if obs.obs_frontend_get_profile_config ~= nil then
        profile_config = obs.obs_frontend_get_profile_config()
    end

    if profile_config ~= nil then
        obs.config_set_string(
            profile_config,
            "Audio",
            "MonitoringDeviceName",
            target_name
        )

        obs.config_set_string(
            profile_config,
            "Audio",
            "MonitoringDeviceId",
            target_id
        )

        -- Persist basic.ini immediately.  OBS will also save its profile during
        -- normal shutdown, but saving here makes the checkbox deterministic.
        if obs.config_save ~= nil then
            local save_result = obs.config_save(profile_config)

            -- CONFIG_SUCCESS is normally 0. Some SWIG builds may expose this
            -- function without a useful return value, so only warn on a known
            -- non-zero numeric result.
            if type(save_result) == "number" and save_result ~= 0 then
                log_warn(
                    "config_save returned " .. tostring(save_result) ..
                    " while saving the OBS monitoring-device setting."
                )
            end
        end
    else
        log_warn(
            "Could not access the current OBS profile config; " ..
            "the live monitoring device will still be changed."
        )
    end

    -- This is the same libobs API used by OBS's Settings dialog when the
    -- Monitoring Device combo changes. It also resets existing audio monitors
    -- internally when the device ID changes.
    local ok = obs.obs_set_audio_monitoring_device(target_name, target_id)

    if not ok then
        log_warn(
            "OBS refused to set Monitoring Device to: " ..
            target_name .. " [" .. target_id .. "]"
        )
    end

    return ok
end


-- ----------------------------------------------------------------------------
-- Playback device discovery
-- ----------------------------------------------------------------------------

local function get_sink_descriptions()
    local descriptions = {}

    if not command_exists("pactl") then
        return descriptions
    end

    local output = command_output("pactl list sinks")
    if not output then
        return descriptions
    end

    local current_name = nil

    for line in output:gmatch("[^\r\n]+") do
        local name = line:match("^%s*Name:%s*(.-)%s*$")
        if name and name ~= "" then
            current_name = name
        else
            local description = line:match("^%s*Description:%s*(.-)%s*$")
            if description and description ~= "" and current_name then
                descriptions[current_name] = description
            end
        end
    end

    return descriptions
end

local function get_playback_nodes()
    local nodes = {}

    if not command_exists("pw-link") then
        return {}
    end

    local output = command_output("pw-link -i")
    if not output then
        return {}
    end

    for line in output:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")

        local node_fl = line:match("^(.*):playback_FL$")
        if node_fl and node_fl ~= VIRTUAL_SINK then
            nodes[node_fl] = nodes[node_fl] or {}
            nodes[node_fl].fl = true
        end

        local node_fr = line:match("^(.*):playback_FR$")
        if node_fr and node_fr ~= VIRTUAL_SINK then
            nodes[node_fr] = nodes[node_fr] or {}
            nodes[node_fr].fr = true
        end
    end

    local descriptions = get_sink_descriptions()
    local result = {}

    -- Only list stereo devices that expose both FL and FR ports.
    -- Keep the PipeWire node name as the value used by pw-link, but attach
    -- Pulse/PipeWire's human-readable Description for the OBS dropdown.
    for node, channels in pairs(nodes) do
        if channels.fl and channels.fr then
            table.insert(result, {
                id = node,
                description = descriptions[node] or node
            })
        end
    end

    table.sort(result, function(a, b)
        local ad = string.lower(a.description or a.id)
        local bd = string.lower(b.description or b.id)
        if ad == bd then
            return a.id < b.id
        end
        return ad < bd
    end)

    -- If two sinks share the same friendly description, disambiguate them
    -- without making every normal entry noisy.
    local counts = {}
    for _, device in ipairs(result) do
        counts[device.description] = (counts[device.description] or 0) + 1
    end

    for _, device in ipairs(result) do
        if counts[device.description] > 1 then
            device.label = device.description .. "  [" .. device.id .. "]"
        else
            device.label = device.description
        end
    end

    return result
end

local function playback_node_exists(node)
    if not node or node == "" then
        return false
    end

    for _, candidate in ipairs(get_playback_nodes()) do
        if candidate.id == node then
            return true
        end
    end

    return false
end


-- ----------------------------------------------------------------------------
-- pw-link routing
-- ----------------------------------------------------------------------------

local function disconnect_from_device(device)
    if not device or device == "" then
        return
    end

    command_ok(
        "pw-link -d " ..
        shell_quote(SOURCE_FL) .. " " ..
        shell_quote(device .. ":playback_FL")
    )

    command_ok(
        "pw-link -d " ..
        shell_quote(SOURCE_FR) .. " " ..
        shell_quote(device .. ":playback_FR")
    )
end

local function disconnect_all_playback_links()
    -- Only disconnect links from OUR virtual monitor ports to playback_FL/FR.
    -- This intentionally does NOT touch the remap-source connection used by
    -- OBS_Virtual_Output_Audio_As_Mic_For_Chrome.
    for _, device in ipairs(get_playback_nodes()) do
        disconnect_from_device(device.id)
    end

    linked_device = ""
end

local function connect_to_device(device)
    if not command_exists("pw-link") then
        log_error("'pw-link' was not found.")
        return false
    end

    if not playback_node_exists(device) then
        log_info("Playback device is unavailable: " .. tostring(device))
        return false
    end

    -- Remove an existing identical link first. This makes reconnect idempotent.
    disconnect_from_device(device)

    local left_ok = command_ok(
        "pw-link " ..
        shell_quote(SOURCE_FL) .. " " ..
        shell_quote(device .. ":playback_FL")
    )

    local right_ok = command_ok(
        "pw-link " ..
        shell_quote(SOURCE_FR) .. " " ..
        shell_quote(device .. ":playback_FR")
    )

    if not left_ok or not right_ok then
        -- Avoid leaving only one channel connected.
        disconnect_from_device(device)

        log_error(
            "Could not create stereo monitor links to: " .. tostring(device)
        )
        return false
    end

    linked_device = device

    return true
end

local function apply_monitoring(force)
    if not ensure_virtual_devices() then
        return
    end

    set_obs_monitoring_device_from_checkbox()

    if not monitor_enabled or selected_device == "" then
        if linked_device ~= "" or force then
            disconnect_all_playback_links()
        end
        return
    end

    if not force and linked_device == selected_device then
        return
    end

    -- The script owns monitor_FL/FR -> physical playback links, so keep only
    -- the currently selected physical device connected.
    disconnect_all_playback_links()
    connect_to_device(selected_device)
end


-- ----------------------------------------------------------------------------
-- OBS script callbacks
-- ----------------------------------------------------------------------------

function script_description()
    return [[
PipeWire virtual audio router for OBS on Linux.

It creates the persistent PipeWire configuration, ensures the virtual sink/mic 
are available in the current session, and lets you listen to the processed OBS monitor output 
through a selected stereo PipeWire playback device. 

Virtual OBS monitoring sink:
  OBS_Virtual_Output_Audio_As_Mic_For_Apps

Chrome-friendly virtual microphone:
  OBS_Virtual_Output_Audio_As_Mic_For_Chrome

The checkbox "Use virtual output as OBS Monitoring Device" directly controls:
  Settings -> Audio -> Advanced -> Monitoring Device
Checked = virtual output; unchecked = Default.

For each OBS audio source you want sent to apps/chrome, set:
  Advanced Audio Properties -> Audio Monitoring -> Monitor and Output
]]
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "auto_set_obs_monitor", true)
    obs.obs_data_set_default_bool(settings, "monitor_enabled", false)
    obs.obs_data_set_default_string(settings, "monitor_device", "")
end

local function refresh_devices_button(props, property)
    -- Returning true asks OBS to rebuild/refresh the properties UI.
    return true
end

local function reconnect_button(props, property)
    apply_monitoring(true)
    return false
end

local function disconnect_button(props, property)
    disconnect_all_playback_links()
    return false
end

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_bool(
        props,
        "auto_set_obs_monitor",
        "Use virtual output as OBS Monitoring Device"
    )

    obs.obs_properties_add_bool(
        props,
        "monitor_enabled",
        "Listen to processed OBS output"
    )

    local device_list = obs.obs_properties_add_list(
        props,
        "monitor_device",
        "Playback device",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )

    obs.obs_property_list_add_string(device_list, "(None)", "")

    local found_selected = (selected_device == "")

    for _, device in ipairs(get_playback_nodes()) do
        -- Visible text = friendly Pulse/PipeWire description.
        -- Stored value  = exact PipeWire node name required by pw-link.
        obs.obs_property_list_add_string(
            device_list,
            device.label,
            device.id
        )

        if device.id == selected_device then
            found_selected = true
        end
    end

    -- Keep a saved device visible even when temporarily unplugged.
    if selected_device ~= "" and not found_selected then
        obs.obs_property_list_add_string(
            device_list,
            selected_device .. " (currently unavailable)",
            selected_device
        )
    end

    obs.obs_properties_add_button(
        props,
        "refresh_devices",
        "Refresh playback devices",
        refresh_devices_button
    )

    obs.obs_properties_add_button(
        props,
        "reconnect",
        "Reconnect selected device",
        reconnect_button
    )

    obs.obs_properties_add_button(
        props,
        "disconnect",
        "Disconnect local monitoring",
        disconnect_button
    )

    return props
end

function script_update(settings)
    auto_set_obs_monitor =
        obs.obs_data_get_bool(settings, "auto_set_obs_monitor")

    monitor_enabled =
        obs.obs_data_get_bool(settings, "monitor_enabled")

    selected_device =
        obs.obs_data_get_string(settings, "monitor_device")

    if bootstrap_done then
        apply_monitoring(false)
    end
end

local function bootstrap_once()
    obs.timer_remove(bootstrap_once)
    bootstrap_done = true

    ensure_virtual_devices()
    apply_monitoring(true)
end

function script_load(settings)
    auto_set_obs_monitor =
        obs.obs_data_get_bool(settings, "auto_set_obs_monitor")

    monitor_enabled =
        obs.obs_data_get_bool(settings, "monitor_enabled")

    selected_device =
        obs.obs_data_get_string(settings, "monitor_device")

    ensure_config_file()

    if not command_exists("pw-link") then
        log_error("'pw-link' was not found. Install PipeWire command-line tools.")
    end

    -- Give OBS/PipeWire a moment to finish enumerating audio devices/ports.
    obs.timer_add(bootstrap_once, 1000)
end

function script_unload()
    obs.timer_remove(bootstrap_once)

    -- Local listening is considered owned by this script.
    -- The persistent virtual sink/mic are deliberately NOT removed.
    disconnect_all_playback_links()
end
