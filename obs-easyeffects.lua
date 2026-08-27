obs = obslua

local protected_source_name = "Mic/Aux"
local easyeffects_source_name = "easyeffects_source"
local poll_interval = 500
local guard_owns_mute = false
local outage_active = false
local outage_source_uuid = nil
local missing_source_logged = false
local availability_warning_logged = false
local startup_checks_remaining = 0
local startup_grace_period_ms = 3000
local release_guard_ownership

local pipewire_workaround = [[stream.rules = [
    {
        matches = [
            {
                application.process.binary = "obs"
                media.class = "Stream/Input/Audio"
                media.name = "Mic/Aux"
            }
        ]
        actions = {
            update-props = {
                node.dont-reconnect = false
                target.object = null
            }
        }
    }
]
]]

local function shell_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function command_succeeded(result, exit_type, exit_code)
    if type(result) == "number" then
        return result == 0
    end
    return result == true and exit_type == "exit" and exit_code == 0
end

local function has_pipewire_workaround(contents)
    local required_lines = {
        'application.process.binary = "obs"',
        'media.class = "Stream/Input/Audio"',
        'media.name = "Mic/Aux"',
        "node.dont-reconnect = false",
        "target.object = null",
    }

    for _, line in ipairs(required_lines) do
        if not contents:find(line, 1, true) then
            return false
        end
    end
    return true
end

local function ensure_pipewire_workaround()
    local home = os.getenv("HOME")
    if home == nil or home == "" then
        obs.script_log(obs.LOG_ERROR,
            "Cannot install the PipeWire workaround because HOME is unavailable")
        return
    end

    local config_dir = home .. "/.config/pipewire/pipewire-pulse.conf.d"
    local config_path = config_dir .. "/obs-movable-capture.conf"
    local existing = io.open(config_path, "r")
    if existing ~= nil then
        local contents = existing:read("*a")
        existing:close()
        if contents ~= nil and has_pipewire_workaround(contents) then
            return
        end
        obs.script_log(obs.LOG_WARNING,
            "PipeWire workaround file is incomplete; replacing it: " .. config_path)
    end

    local result, exit_type, exit_code = os.execute(
        "mkdir -p -- " .. shell_quote(config_dir) .. " >/dev/null 2>&1")
    if not command_succeeded(result, exit_type, exit_code) then
        obs.script_log(obs.LOG_ERROR,
            "Could not create the PipeWire configuration directory: " .. config_dir)
        return
    end

    local temporary_path = config_path .. ".tmp"
    local output, open_error = io.open(temporary_path, "w")
    if output == nil then
        obs.script_log(obs.LOG_ERROR,
            "Could not write the PipeWire workaround: " .. tostring(open_error))
        return
    end

    local wrote, write_error = output:write(pipewire_workaround)
    local closed, close_error = output:close()
    if wrote == nil or closed == nil then
        os.remove(temporary_path)
        obs.script_log(obs.LOG_ERROR,
            "Could not write the PipeWire workaround: " ..
                tostring(write_error or close_error))
        return
    end

    local renamed, rename_error = os.rename(temporary_path, config_path)
    if not renamed then
        os.remove(temporary_path)
        obs.script_log(obs.LOG_ERROR,
            "Could not install the PipeWire workaround: " .. tostring(rename_error))
        return
    end

    result, exit_type, exit_code = os.execute(
        "timeout --signal=KILL 5s systemctl --user restart pipewire-pulse.service " ..
            ">/dev/null 2>&1")
    if not command_succeeded(result, exit_type, exit_code) then
        obs.script_log(obs.LOG_WARNING,
            "Workaround installed, but pipewire-pulse could not be restarted; " ..
                "it will apply after the next restart")
    end
end

local function probe_source(source_name)
    local command = "timeout --signal=KILL 0.2s pactl get-source-mute " .. shell_quote(source_name) ..
        " >/dev/null 2>&1"
    local result, exit_type, exit_code = os.execute(command)
    return command_succeeded(result, exit_type, exit_code)
end

local function handle_availability(available, suppress_startup_warning)
    if available then
        availability_warning_logged = false
    elseif not suppress_startup_warning and not availability_warning_logged then
        obs.script_log(obs.LOG_WARNING,
            "EasyEffects source is unavailable; muting the protected OBS source")
        availability_warning_logged = true
    end

    local source = obs.obs_get_source_by_name(protected_source_name)
    if source == nil then
        if not suppress_startup_warning and not missing_source_logged then
            obs.script_log(obs.LOG_WARNING,
                "Protected OBS source not found: " .. protected_source_name)
            missing_source_logged = true
        end
        return
    end
    missing_source_logged = false
    local source_uuid = obs.obs_source_get_uuid(source)

    if outage_active and outage_source_uuid ~= source_uuid then
        release_guard_ownership()
    end

    if not available and not outage_active then
        outage_active = true
        outage_source_uuid = source_uuid
        guard_owns_mute = not obs.obs_source_muted(source)
    end

    if not available then
        if not obs.obs_source_muted(source) then
            obs.obs_source_set_muted(source, true)
        end
    elseif outage_active then
        if guard_owns_mute then
            obs.obs_source_set_muted(source, false)
        end
        guard_owns_mute = false
        outage_active = false
        outage_source_uuid = nil
    end

    obs.obs_source_release(source)
end

local function check_now()
    local suppress_startup_warning = startup_checks_remaining > 0
    if suppress_startup_warning then
        startup_checks_remaining = startup_checks_remaining - 1
    end
    handle_availability(probe_source(easyeffects_source_name), suppress_startup_warning)
end

release_guard_ownership = function()
    if guard_owns_mute then
        local source = nil
        if outage_source_uuid ~= nil then
            source = obs.obs_get_source_by_uuid(outage_source_uuid)
        end
        if source == nil then
            source = obs.obs_get_source_by_name(protected_source_name)
        end
        if source ~= nil then
            if obs.obs_source_get_uuid(source) == outage_source_uuid and
                obs.obs_source_muted(source) then
                obs.obs_source_set_muted(source, false)
            end
            obs.obs_source_release(source)
        end
    end
    guard_owns_mute = false
    outage_active = false
    outage_source_uuid = nil
end

local function is_outage_source(source_name)
    if not outage_active or outage_source_uuid == nil then
        return false
    end

    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then
        return false
    end
    local matches = obs.obs_source_get_uuid(source) == outage_source_uuid
    obs.obs_source_release(source)
    return matches
end

function script_description()
    return "1-Mutes a selected OBS audio source whenever the EasyEffects PipeWire source " ..
        "is unavailable, safely restores a mute owned by this guard on recovery. " ..
        "2-Installs OBS Easy Effects Workaround."
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "protected_source", "Mic/Aux")
    obs.obs_data_set_default_string(settings, "easyeffects_source", "easyeffects_source")
    obs.obs_data_set_default_int(settings, "poll_interval", 500)
end

function script_properties()
    local properties = obs.obs_properties_create()
    obs.obs_properties_add_text(properties, "protected_source", "Protected OBS source",
        obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(properties, "easyeffects_source", "EasyEffects source",
        obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_int_slider(properties, "poll_interval", "Poll interval (ms)",
        100, 5000, 100)
    return properties
end

function script_update(settings)
    obs.timer_remove(check_now)

    local configured_source = obs.obs_data_get_string(settings, "protected_source")
    if configured_source ~= "" and configured_source ~= protected_source_name then
        if not is_outage_source(configured_source) then
            release_guard_ownership()
        end
        protected_source_name = configured_source
        missing_source_logged = false
    end

    local configured_easyeffects = obs.obs_data_get_string(settings, "easyeffects_source")
    if configured_easyeffects ~= "" then
        easyeffects_source_name = configured_easyeffects
    end

    local configured_interval = obs.obs_data_get_int(settings, "poll_interval")
    if configured_interval > 0 then
        poll_interval = math.max(100, math.min(5000, configured_interval))
    end

    startup_checks_remaining = math.max(1, math.ceil(startup_grace_period_ms / poll_interval))
    check_now()
    obs.timer_add(check_now, poll_interval)
end

function script_load()
    ensure_pipewire_workaround()
end

function script_unload()
    obs.timer_remove(check_now)
    handle_availability(probe_source(easyeffects_source_name))
end

return {
    check_now = check_now,
    handle_availability = handle_availability,
    probe_source = probe_source,
}
