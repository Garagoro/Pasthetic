local M = {}

local LOGO_URL_DEFAULT = 'https://raw.githubusercontent.com/Garagoro/Pasthetic/refs/heads/main/logo%202.png'
local MESSAGE_MAGIC = 'PTH_SHARED_LOGO'
local MESSAGE_VERSION = '1'
local HEARTBEAT_INTERVAL = 1.25
local SCOREBOARD_INTERVAL = 1.0
local PLAYER_TTL = 7.0

function M.start(ctx)
    ctx = ctx or {}

    local globals = ctx.globals or globals
    local entity = ctx.entity or entity
    local client = ctx.client or client
    local panorama = ctx.panorama or panorama

    local voice_message = require 'voice_message'

    local LOGO_URL = (function()
        local src = readfile and readfile('pasthetic\\creator_logo.lua')
        if type(src) == 'string' then
            local chunk = loadstring(src)
            if chunk then
                local ok, val = pcall(chunk)
                if ok and type(val) == 'string' then return val end
            end
        end
        return LOGO_URL_DEFAULT
    end)()

    local shared_players = {}
    local last_seen = {}
    local last_heartbeat = 0
    local last_scoreboard_update = 0

    local scoreboard_images = panorama.loadstring([[
        var name_panels = {};
        var target_players = {};
        var logo_url = "";

        var _GetScoreboard = function() {
            var root = $.GetContextPanel();
            if (!root) return null;

            var container = root.FindChildTraverse("ScoreboardContainer");
            if (!container) return null;

            return container.FindChildTraverse("Scoreboard");
        };

        var _RemovePanels = function() {
            for (var xuid in name_panels) {
                if (name_panels[xuid] && name_panels[xuid].IsValid()) {
                    name_panels[xuid].DeleteAsync(0.0);
                }
            }

            name_panels = {};
        };

        var _Destroy = function() {
            _RemovePanels();

            var scoreboard = _GetScoreboard();
            if (!scoreboard) return;

            scoreboard.FindChildrenWithClassTraverse("sb-row").forEach(function(row) {
                row.Children().forEach(function(child) {
                    var nameLabel = child.FindChildTraverse("name");
                    if (nameLabel) {
                        nameLabel.style.color = null;
                        nameLabel.style.fontFamily = "Stratum2";
                        nameLabel.style.fontWeight = "normal";
                    }
                });
            });
        };

        var _Update = function(players, imageUrl) {
            target_players = players || {};
            logo_url = imageUrl || logo_url;

            _Destroy();

            var scoreboard = _GetScoreboard();
            if (!scoreboard) return;

            scoreboard.FindChildrenWithClassTraverse("sb-row").forEach(function(row) {
                var xuid = String(row.m_xuid || "");
                if (!target_players[xuid]) return;

                row.Children().forEach(function(child) {
                    var nameLabel = child.FindChildTraverse("name");
                    if (!nameLabel) return;

                    nameLabel.style.color = "rgb(190, 205, 255)";
                    nameLabel.style.fontFamily = "Stratum2 Bold Monodigit";
                    nameLabel.style.fontWeight = "bold";

                    var parent = nameLabel.GetParent();
                    if (!parent) return;

                    parent.style.flowChildren = "left";

                    var image_panel = $.CreatePanel("Panel", parent, "pasthetic_shared_logo_" + xuid);
                    var layout = ''
                        + '<root>'
                        + '    <Panel style="flow-children: left; margin-right: 5px;">'
                        + '        <Image textureheight="24" texturewidth="24" src="' + logo_url + '" />'
                        + '    </Panel>'
                        + '</root>';

                    image_panel.BLoadLayoutFromString(layout, false, false);
                    parent.MoveChildBefore(image_panel, nameLabel);
                    name_panels[xuid] = image_panel;
                });
            });
        };

        return {
            update: _Update,
            remove: _Destroy
        };
    ]], "CSGOHud")()

    local function get_local_xuid()
        local ok, xuid = pcall(function()
            return panorama.open().MyPersonaAPI.GetXuid()
        end)

        if not ok or xuid == nil then
            return nil
        end

        xuid = tostring(xuid)

        if xuid == '' or xuid == '0' then
            return nil
        end

        return xuid
    end

    local function mark_shared_player(xuid)
        if xuid == nil or xuid == '' then
            return
        end

        shared_players[xuid] = true
        last_seen[xuid] = globals.realtime()
    end

    local function mark_local_player()
        mark_shared_player(get_local_xuid())
    end

    local function cleanup_shared_players()
        local now = globals.realtime()
        local local_xuid = get_local_xuid()

        for xuid, seen_at in pairs(last_seen) do
            if xuid ~= local_xuid and now - seen_at > PLAYER_TTL then
                last_seen[xuid] = nil
                shared_players[xuid] = nil
            end
        end
    end

    local function update_scoreboard()
        scoreboard_images.update(shared_players, LOGO_URL)
    end

    local function send_heartbeat()
        if entity.get_local_player() == nil then
            return
        end

        local xuid = get_local_xuid()

        if xuid == nil then
            return
        end

        mark_shared_player(xuid)

        voice_message.send(function(buf)
            buf:write_string(MESSAGE_MAGIC)
            buf:write_string(MESSAGE_VERSION)
            buf:write_string(xuid)
        end)
    end

    voice_message(function(buf)
        local magic = buf:read_string()

        if magic ~= MESSAGE_MAGIC then
            return
        end

        local version = buf:read_string()

        if version ~= MESSAGE_VERSION then
            return
        end

        local xuid = buf:read_string()

        if xuid == nil or xuid == '' then
            return
        end

        mark_shared_player(xuid)
    end)

    client.set_event_callback('player_connect_full', function()
        client.delay_call(0.25, function()
            send_heartbeat()
            update_scoreboard()
        end)
    end)

    client.set_event_callback('paint', function()
        local now = globals.realtime()

        if now - last_heartbeat >= HEARTBEAT_INTERVAL then
            send_heartbeat()
            last_heartbeat = now
        end

        if now - last_scoreboard_update >= SCOREBOARD_INTERVAL then
            cleanup_shared_players()
            update_scoreboard()
            last_scoreboard_update = now
        end
    end)

    client.set_event_callback('shutdown', function()
        scoreboard_images.remove()
    end)

    mark_local_player()
    update_scoreboard()
end

return M
