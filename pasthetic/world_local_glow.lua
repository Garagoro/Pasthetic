local M = {}

function M.start(deps)
    local resource = assert(deps.resource, 'world_local_glow: resource dependency is required')
    local ffi = assert(deps.ffi, 'world_local_glow: ffi dependency is required')
    local client = deps.client or client
    local entity = deps.entity or entity
    local utils = assert(deps.utils, 'world_local_glow: utils dependency is required')

    ffi.cdef [[
        struct PastheticGlowVector
        {
            float r, g, b;
        };

        struct PastheticGlowAllocator
        {
            struct PastheticGlowObjectDefinition *m_pMemory;
            int m_nAllocationCount;
            int m_nGrowSize;
        };

        struct PastheticGlowVectorStorage
        {
            struct PastheticGlowAllocator m_Memory;
            int m_Size;
            struct PastheticGlowObjectDefinition *m_pElements;
        };

        struct PastheticGlowObjectDefinition
        {
            int m_nNextFreeSlot;
            void *m_pEntity;
            struct PastheticGlowVector m_vGlowColor;
            float m_flGlowAlpha;
            char pad01[16];
            bool m_bRenderWhenOccluded;
            bool m_bRenderWhenUnoccluded;
            bool m_bFullBloomRender;
            char pad02;
            int m_nFullBloomStencilTestValue;
            int m_nRenderStyle;
            int m_nSplitScreenSlot;
        };

        struct PastheticGlowObjectManager
        {
            struct PastheticGlowVectorStorage m_GlowObjectDefinitions;
            int m_nFirstFreeSlot;
        };
    ]]

    local ref = resource.render_we.world.local_player_glow
    local glow_styles = {
        'Default',
        'Rim Glow 3D',
        'Edge Highlight',
        'Edge Highlight Pulse'
    }

    local function read_uint(address)
        return ffi.cast('unsigned int*', address)[0]
    end

    local function find_signature(module_name, signature)
        return client.find_signature(module_name, signature)
    end

    local function require_signature(module_name, signature, name)
        local address = find_signature(module_name, signature)

        if address == nil then
            error(name .. ' signature not found')
        end

        return address
    end

    local function require_interface(module_name, interface_name)
        local interface = client.create_interface(module_name, interface_name)

        if interface == nil then
            error(interface_name .. ' interface not found')
        end

        return interface
    end

    local client_entity_list = require_interface('client.dll', 'VClientEntityList003')
    local engine_client = require_interface('engine.dll', 'VEngineClient014')

    local register_glow_call = ffi.cast(
        'unsigned int',
        require_signature('client.dll', '\xE8\xCC\xCC\xCC\xCC\x89\x03\xEB\x02', 'RegisterGlowObject')
    )
    local register_glow_object = ffi.cast(
        'int(__thiscall*)(struct PastheticGlowObjectManager*, void*, const struct PastheticGlowVector&, bool, bool, int)',
        register_glow_call + 5 + read_uint(register_glow_call + 1)
    )
    local get_glow_object_manager = ffi.cast(
        'struct PastheticGlowObjectManager*(__cdecl*)()',
        require_signature('client.dll', '\xA1\xCC\xCC\xCC\xCC\xA8\x01\x75\x4B', 'GetGlowObjectManager')
    )
    local get_client_entity_raw = ffi.cast(
        'void*(__thiscall*)(void*, int)',
        read_uint(read_uint(ffi.cast('unsigned int', client_entity_list)) + 3 * 4)
    )
    local is_in_game_raw = ffi.cast(
        'bool(__thiscall*)(void*)',
        read_uint(read_uint(ffi.cast('unsigned int', engine_client)) + 26 * 4)
    )

    local glow_object_indexes = {}
    local old_color = { r = 255, g = 255, b = 255, a = 255 }

    local function get_client_entity(index)
        return get_client_entity_raw(client_entity_list, index)
    end

    local function is_in_game()
        return is_in_game_raw(engine_client)
    end

    local function get_color()
        local r, g, b, a = ref.color:get()

        return {
            r = r or 255,
            g = g or 255,
            b = b or 255,
            a = a or 255
        }
    end

    local function to_glow_color(color)
        return ffi.new('struct PastheticGlowVector', {
            (color.r or 255) / 255,
            (color.g or 255) / 255,
            (color.b or 255) / 255
        })
    end

    local function get_style_index()
        local style = ref.style:get()

        for i = 1, #glow_styles do
            if glow_styles[i] == style then
                return i - 1
            end
        end

        return 0
    end

    local function create_glow_object(ent, color, alpha, style)
        if ent == nil then
            return
        end

        local glow_object_manager = get_glow_object_manager()

        if glow_object_manager == nil then
            return
        end

        local index = register_glow_object(
            glow_object_manager,
            ffi.cast('void*', ent),
            to_glow_color(color),
            true,
            true,
            -1
        )
        local object = glow_object_manager.m_GlowObjectDefinitions.m_Memory.m_pMemory[index]

        object.m_vGlowColor = to_glow_color(color)
        object.m_flGlowAlpha = alpha
        object.m_nRenderStyle = style
        object.m_bRenderWhenOccluded = true
        object.m_bRenderWhenUnoccluded = true

        glow_object_indexes[#glow_object_indexes + 1] = index
    end

    local function set_glow_object_color(index, color)
        local glow_object_manager = get_glow_object_manager()

        if glow_object_manager == nil then
            return
        end

        local object = glow_object_manager.m_GlowObjectDefinitions.m_Memory.m_pMemory[index]
        object.m_vGlowColor = to_glow_color(color)
        object.m_flGlowAlpha = (color.a or 255) / 255
    end

    local function set_glow_object_render(index, status)
        local glow_object_manager = get_glow_object_manager()

        if glow_object_manager == nil then
            return
        end

        local object = glow_object_manager.m_GlowObjectDefinitions.m_Memory.m_pMemory[index]
        object.m_bRenderWhenOccluded = status
        object.m_bRenderWhenUnoccluded = status
    end

    local function update_render_state()
        local enabled = ref.enable:get()
        local style = get_style_index()

        for i = 1, #glow_object_indexes do
            set_glow_object_render(glow_object_indexes[i], enabled and style + 1 == i)
        end
    end

    local function init_glow_objects()
        if #glow_object_indexes > 0 then
            return
        end

        local local_player = entity.get_local_player()

        if local_player == nil then
            return
        end

        local local_entity = get_client_entity(local_player)

        if local_entity == nil then
            return
        end

        local color = get_color()

        create_glow_object(local_entity, color, color.a / 255, 0)
        create_glow_object(local_entity, color, color.a / 255, 1)
        create_glow_object(local_entity, color, color.a / 255, 2)
        create_glow_object(local_entity, color, color.a / 255, 3)

        for i = 1, #glow_object_indexes do
            set_glow_object_color(glow_object_indexes[i], color)
        end

        old_color = color
        update_render_state()
    end

    local function remove_glow_objects()
        local glow_object_manager = get_glow_object_manager()

        if glow_object_manager == nil then
            glow_object_indexes = {}
            return
        end

        for i = 1, #glow_object_indexes do
            local index = glow_object_indexes[i]
            local object = glow_object_manager.m_GlowObjectDefinitions.m_Memory.m_pMemory[index]

            object.m_nNextFreeSlot = glow_object_manager.m_nFirstFreeSlot
            object.m_pEntity = ffi.cast('void*', 0)
            glow_object_manager.m_nFirstFreeSlot = index
        end

        glow_object_indexes = {}
    end

    local function on_paint_ui()
        if is_in_game() then
            if #glow_object_indexes == 0 then
                init_glow_objects()
            end

            local color = get_color()

            if color.r ~= old_color.r
                or color.g ~= old_color.g
                or color.b ~= old_color.b
                or color.a ~= old_color.a
            then
                for i = 1, #glow_object_indexes do
                    set_glow_object_color(glow_object_indexes[i], color)
                end

                old_color = color
            end
        elseif #glow_object_indexes > 0 then
            remove_glow_objects()
        end
    end

    local function on_player_connect_full(event)
        local local_player = entity.get_local_player()
        local connected_player = client.userid_to_entindex(event.userid)

        if local_player ~= nil and connected_player == local_player then
            remove_glow_objects()
            init_glow_objects()
        end
    end

    ref.enable:set_callback(update_render_state)
    ref.style:set_callback(update_render_state)

    utils.event_callback('paint_ui', on_paint_ui, true)
    utils.event_callback('player_connect_full', on_player_connect_full, true)
    utils.event_callback('shutdown', remove_glow_objects, true)

    if is_in_game() then
        init_glow_objects()
    end

    return {
        remove = remove_glow_objects
    }
end

return M
