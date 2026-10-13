-- GC unlock for csgo_legacy (ClientVersion 1575): reports a CS2-era client
-- version to the GC and lifts the startup license gate, which restores the
-- inventory without editing csgo/steam.inf. Runs automatically, no menu items.
-- Offsets are for the frozen csgo_legacy build (engine.dll Aug 24 2023).

local M = {}

-- engine.dll: values parsed from steam.inf once at startup
local RVA_ENGINE_CLIENT_VERSION = 0x390C2DC
local RVA_ENGINE_SERVER_VERSION = 0x390C2E4

-- client.dll: static CCSGCClientSystem, CGCClient lives at +0x70
local RVA_GC_CLIENT_SYSTEM = 0x5270AD0
local RVA_GC_CLIENT_SYSTEM_VTABLE = 0x0CAC32C
local GC_CLIENT_OFFSET = 0x70

-- client.dll: bit 0 = "don't need a GC session", set by the license init.
-- While it is set, Update writes need_session = 0 and Panorama shows the
-- License Assist "unsupported" dialog for the reason code below.
local RVA_GC_SESSION_GATE = 0x0E0AC58
local RVA_LICENSE_REASON = 0x0E0AC50

-- Panorama notifiers the client's own unlock path (0x106336C0) fires
local RVA_NOTIFY_LICENSE_A = 0x063E800
local RVA_NOTIFY_LICENSE_B = 0x063E880

-- CGCClient fields
local GC_HELLO_RETRY_COUNT = 0x390
local GC_NEXT_HELLO_TIME = 0x398 -- uint64
local GC_VERSION = 0x3B0
local GC_CONNECTION_STATUS = 0x3B4

local GC_STATUS_NO_SESSION = 2
local LEGACY_VERSION = 1575
local FALLBACK_VERSION = 2000303
local CS2_STEAM_INF = 'game/csgo/steam.inf'

function M.start(deps)
    deps = deps or {}

    local ffi = deps.ffi or ffi
    local bit = deps.bit or bit
    local client = deps.client or client
    local state = {}

    local uintptr_t = ffi.typeof('uintptr_t')

    local function read_u32(address)
        return tonumber(ffi.cast('uint32_t*', address)[0]) or 0
    end

    local function read_i32(address)
        return tonumber(ffi.cast('int32_t*', address)[0]) or 0
    end

    local function write_i32(address, value)
        ffi.cast('int32_t*', address)[0] = value
    end

    local function write_u32(address, value)
        ffi.cast('uint32_t*', address)[0] = value
    end

    local function opcode_scan(module_name, pattern)
        local result = client.find_signature(module_name, pattern)

        if result == nil then
            error('gc_unlock: signature not found in ' .. module_name)
        end

        return tonumber(ffi.cast(uintptr_t, result)) or 0
    end

    -- GetModuleHandleA through engine's import via a `jmp ecx` gadget (ffi.C is unavailable)
    local jmp_ecx = opcode_scan('engine.dll', '\xFF\xE1')
    local get_module_handle_ptr = read_u32(read_u32(opcode_scan('engine.dll', '\xFF\x15\xCC\xCC\xCC\xCC\x85\xC0\x74\x0B') + 2))
    local get_module_handle_raw = ffi.cast('uint32_t(__fastcall*)(uint32_t, uint32_t, const char*)', jmp_ecx)

    local function get_module_base(module_name)
        return tonumber(get_module_handle_raw(get_module_handle_ptr, 0, module_name)) or 0
    end

    local engine_base = get_module_base('engine.dll')
    local client_base = get_module_base('client.dll')

    if engine_base == 0 or client_base == 0 then
        error('gc_unlock: engine.dll/client.dll not found')
    end

    local gc_system = client_base + RVA_GC_CLIENT_SYSTEM
    local gc_client = gc_system + GC_CLIENT_OFFSET
    local engine_client_version = engine_base + RVA_ENGINE_CLIENT_VERSION
    local engine_server_version = engine_base + RVA_ENGINE_SERVER_VERSION
    local gc_session_gate = client_base + RVA_GC_SESSION_GATE
    local license_reason = client_base + RVA_LICENSE_REASON

    -- Wrong build: the offsets would point at garbage, so stay inert
    if read_u32(gc_system) ~= client_base + RVA_GC_CLIENT_SYSTEM_VTABLE then
        client.log('[Pasthetic] GC unlock skipped: unknown client.dll build')
        return state
    end

    local notify_license_a = ffi.cast('void(__cdecl*)(void)', client_base + RVA_NOTIFY_LICENSE_A)
    local notify_license_b = ffi.cast('void(__cdecl*)(void)', client_base + RVA_NOTIFY_LICENSE_B)

    local target_version = FALLBACK_VERSION

    if readfile ~= nil then
        local ok, body = pcall(readfile, CS2_STEAM_INF)
        target_version = ok and body ~= nil and tonumber(body:match('ClientVersion=(%d+)')) or FALLBACK_VERSION
    end

    local original = {
        engine_client = read_i32(engine_client_version),
        engine_server = read_i32(engine_server_version),
        gc = read_i32(gc_client + GC_VERSION)
    }

    -- Drop the session and the hello timer: CGCClient::Think sends a fresh
    -- ClientHello (with the version from +0x3B0) on the next frame.
    local function request_hello()
        write_i32(gc_client + GC_CONNECTION_STATUS, GC_STATUS_NO_SESSION)
        write_u32(gc_client + GC_NEXT_HELLO_TIME, 0)
        write_u32(gc_client + GC_NEXT_HELLO_TIME + 4, 0)
        write_i32(gc_client + GC_HELLO_RETRY_COUNT, 0)
    end

    local function apply()
        local need_hello = false

        -- GC client may (re)initialise after us and cache the legacy version again
        if read_i32(gc_client + GC_VERSION) ~= target_version then
            write_i32(engine_client_version, target_version)
            write_i32(engine_server_version, target_version)
            write_i32(gc_client + GC_VERSION, target_version)
            need_hello = true
        end

        -- The license init can run lazily after us and set the gate again
        local gate = read_u32(gc_session_gate)

        if bit.band(gate, 1) ~= 0 then
            write_u32(gc_session_gate, bit.band(gate, 0xFFFFFFFE))
            write_i32(license_reason, 0)
            notify_license_a()
            notify_license_b()
            need_hello = true
        end

        if need_hello then
            request_hello()
            state.applied = (state.applied or 0) + 1
        end
    end

    apply()
    client.log(string.format('[Pasthetic] GC unlock: ClientVersion %d -> %d', original.gc, target_version))

    client.set_event_callback('paint_ui', apply)

    client.set_event_callback('shutdown', function()
        write_i32(engine_client_version, original.engine_client)
        write_i32(engine_server_version, original.engine_server)

        if original.gc == LEGACY_VERSION then
            write_i32(gc_client + GC_VERSION, original.gc)
        end
    end)

    state.target_version = target_version
    state.original = original

    return state
end

return M
