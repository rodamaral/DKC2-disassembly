local function remove(data, value)
	data = table.remove(data, value)
	if type(data) == "nil" then
		data = {}
	end
	return data
end

local function write_long(value, offset)
	memory2.WRAM:write(bit.band(value, 0xFF), offset)
	memory2.WRAM:write(bit.band(bit.lrshift(value, 8), 0xFF), offset+1)
	memory2.WRAM:write(bit.lrshift(value, 16), offset+2)
end

local function write_word(value, offset)
	memory2.WRAM:write(bit.band(value, 0xFF), offset)
	memory2.WRAM:write(bit.lrshift(value, 8), offset+1)
end

local function write_byte(value, offset)
	memory2.WRAM:write(value, offset)
end


local function read_long(offset)
	return memory2.WRAM:read(offset) + (memory2.WRAM:read(offset+1)*0x100) + (memory2.WRAM:read(offset+1)*0x10000)
end

local function read_word(offset)
	return memory2.WRAM:read(offset) + (memory2.WRAM:read(offset+1)*0x100)
end

local function read_byte(offset)
	return memory2.WRAM:read(offset)
end

local function read_rom_long(offset)
	return memory2.ROM:read(offset) + (memory2.ROM:read(offset+1)*0x100) + (memory2.ROM:read(offset+1)*0x10000)
end

local function read_rom_word(offset)
	return memory2.ROM:read(offset) + (memory2.ROM:read(offset+1)*0x100)
end

local function read_rom_byte(offset)
	return memory2.ROM:read(offset)
end

local function to_pc(address)
	return bit.band(address, 0x3FFFFF)
end

--ROM writing functions, use with caution
local rom_write_buffer = {}

local function rom_preserve(address, size)
	address = to_pc(address)
	if type(rom_write_buffer[address]) == "nil" then
		rom_write_buffer[address] = memory2.ROM:readregion(address, size)
	end
end

local function rom_restore(address)
	memory2.ROM:writeregion(address, rom_write_buffer[address])
	rom_write_buffer = remove(rom_write_buffer, address)
end

local function rom_restore_all(address)
	for address, data in pairs(rom_write_buffer) do 
		print(address, data, type(data))
		memory2.ROM:writeregion(address, data)
	end
	rom_write_buffer = {}
end

local function write_rom_byte(byte, address)
	memory2.ROM:write(byte, to_pc(address))
end

local function write_rom_byte_preserve(byte, address)
	rom_preserve(address, 1)
	memory2.ROM:write(byte, to_pc(address))
end

local function write_rom_nop(address, size)
	rom_preserve(address, size)
	for i=1,size do
		write_rom_byte(0xEA, address + i - 1)
	end
end

local function write_rom_zero(address, size)
	rom_preserve(address, size)
	for i=1,size do
		write_rom_byte(0x00, address + i - 1)
	end
end

local function write_rom_patch(address, data)
	rom_preserve(address, #data)
	for i=1,#data do
		write_rom_byte(data[i], address + i - 1)
	end
end

--print registers register stop
local function write_rom_stop(address)
	rom_preserve(address, 4)
	write_rom_byte(0x9C, address + 0)
	write_rom_byte(0x02, address + 1)
	write_rom_byte(0x50, address + 2)
	write_rom_byte(0xDB, address + 3)
end

local function register(reg)
	return memory.getregister(reg)
end

local function bg_register(reg, i)
	return memory.getregister("ppu_bg_" .. reg .. "[" .. i .. "]")
end

--debug screens
local sprite_screen = 0
local sound_screen = sprite_screen + 1
local camera_screen = sound_screen + 1
local engine_screen = camera_screen + 1
local level_screen = engine_screen + 1
local watch_screen = level_screen + 1

--debug slot Used for screens which have multiple pages
local slot = 0
local play_sound_effect = false

--debug display control
local show_debug = true
local show_dma_debug = false
local active_screen = sprite_screen
local opacity = 0x80
local fg_color = 0x00FFFFFF
local bg_color = 0x00000000
local x_padding = -400
local y_padding = 0

--Add transparency to a color with default opacity
local function trans(color)
	return color + (opacity * 0x1000000)
end

local function text(x, y, message)
	gui.text(x+x_padding, y+y_padding, message, trans(fg_color), trans(bg_color))
end

function clamp(value, low, high)
	if(value < low) then 
		return low 
	elseif(value > high) then 
		return high 
	end
	return value
end

local function byte_table(offset, first, last)
	local table = ""
	offset = offset + first
	count = last - first
	for i=0,count do
		if i % 0x10 == 0x00 and i > 0 then
			table = table .. "\n"
		end
		table = table .. " " .. string.format("%02X", read_byte(offset+i))
	end
	return table
end

local tracked_addresses = {}
local function store(address, value)
	if(value == 0x00) then 
		return
	end
	tracked_addresses[address] = value
end

--This is used for tracking values which are STZed after use
local track_read_buffer = 0
local function track(address, size)
	tracked_addresses[address] = 0
	if size == 1 then
		memory2.WRAM:registerread(address, function(addr, value) store(address, value) end)
	elseif size == 2 then
		memory2.WRAM:registerread(address+0, function(addr, value) track_read_buffer = value end)
		memory2.WRAM:registerread(address+1, function(addr, value) store(address, track_read_buffer + value * 0x100) end)
	end
end


local traced_addresses = {}
local function handle_trace(address, value)
	if(value == 0x00) then 
		return
	end
	tracked_addresses[address] = value
end

local trace_read_buffer = 0
local function trace(address, size)
	tracked_addresses[address] = 0
	if size == 1 then
		memory2.WRAM:registerread(address, function(addr, value) handle_trace(address, value) end)
	elseif size == 2 then
		memory2.WRAM:registerread(address+0, function(addr, value) trace_read_buffer = value end)
		memory2.WRAM:registerread(address+1, function(addr, value) handle_trace(address, trace_read_buffer + value * 0x100) end)
	end
end

local sprite_table = 0x0DE2
local function display_sprite()
	local sprite_slot = clamp(slot, 0, 23)
	local slot_offset = sprite_table + sprite_slot * 0x5E
	local sprite_string = "Slot number (0x%04X): %d\n" ..
				"Sprite number(0x00): %04X\n" ..
				"Render order(0x02): %04X\n" ..
				"Position(0x04/0x08): (%04X.%04X, %04X.%04X)\n" ..
				"Potential Ground(0x0C): %04X\n" ..
				"Ground Distance(0x0E): %04X\n" ..
				"Interaction type(0x10): %04X\n" ..
				"OAM property+tile(0x12): %04X\n" ..
				"Unknown data(0x14): %04X\n" ..
				"Sprite frame (0x16-0x1A): (%04X, %04X, %04X)\n" ..
				"Unknown data(0x1C): %04X\n" ..
				"On Ground(0x1E): %04X\n" ..
				"X speed(0x20): %02X.%02X\n" ..
				"Unknown data(0x22): %04X\n" ..
				"Y speed(0x24): %02X.%02X\n" ..
				"Max X speed(0x26): %02X.%02X\n" ..
				"Unknown data(0x28):\n%s\n" ..
				"Sprite action(0x2E):%04X\n" ..
				"Unknown data(0x30):\n%s\n" ..
				"Status index(0x56):%04X\n" ..
				"Spawn code(0x58):%04X\n" ..
				"Unknown data(0x5A):\n%s\n"
	
	text(0, 0, string.format(sprite_string, 
					slot_offset, sprite_slot,					--current slot
					read_word(slot_offset), 					--Sprite number
					read_word(slot_offset+0x02),					--Render order
					read_word(slot_offset+0x06), read_word(slot_offset+0x04),	--X position
					read_word(slot_offset+0x0A), read_word(slot_offset+0x08),	--Y position
					read_word(slot_offset+0x0C),					--Potential ground height (7F00 == no ground)
					read_word(slot_offset+0x0E),					--Potential ground distance (80xx == no ground)
					read_word(slot_offset+0x010),					--Interaction type, dictates movements relative to blocks
					read_word(slot_offset+0x012),					--YXPPCCCCT TTTTTTTT properties
					read_word(slot_offset+0x014),					--Unknown
					read_word(slot_offset+0x16),					--Sprite frame copy 1
					read_word(slot_offset+0x18),					--Sprite frame copy 2
					read_word(slot_offset+0x1A),					--Sprite frame primary
					read_word(slot_offset+0x1C),					--Unknown
					read_word(slot_offset+0x1E),					--On Ground
					read_byte(slot_offset+0x21), read_byte(slot_offset+0x20), 	--X speed
					read_word(slot_offset+0x22),					--Unknown
					read_byte(slot_offset+0x25), read_byte(slot_offset+0x24), 	--Y speed
					read_byte(slot_offset+0x27), read_byte(slot_offset+0x26),	--Max X speed
					byte_table(slot_offset, 0x28, 0x2D),				--Unknown
					read_word(slot_offset+0x2E),					--Sprite action
					byte_table(slot_offset, 0x30, 0x55),				--Unknown
					read_word(slot_offset+0x56),					--Status index
					read_word(slot_offset+0x58),					--Spawn code
					byte_table(slot_offset, 0x5A, 0x5E)				--Unknown
				))
end

local sound_effect_map = {
	"0x00 -- Nothing",
	"0x01 -- Nothing?",
	"0x02 -- Klomp walking",
	"0x03 -- Monkey sound (unused)",
	"0x04 -- Spin/cartwheel into enemy",
	"0x05 -- Switch Kongs",
	"0x06 -- Diddy hurt/lost",
	"0x07 -- Dixie hurt/lost",
	"0x08 -- Collect bananna",
	"0x09 -- Collect something (unused)",
	"0x0A -- Diddy loses life",
	"0x0B -- Rambi charging",
	"0x0C -- Something breaking (investigate)",
	"0x0D -- Zinger like sound (investigate)",
	"0x0E -- Zinger killed",
	"0x0F -- Klick-Klack walking",
	"0x10 -- Klick-Klack splat",
	"0x11 -- Klobber skidding",
	"0x12 -- Klobber waking up",
	"0x13 -- Quiet sound (investigate)",
	"0x14 -- Explosion of some sort (investigate)",
	"0x15 -- Kannon shooting",
	"0x16 -- Klampon eating player",
	"0x17 -- Klampon snapping jaw while walking",
	"0x18 -- Jump on kroc type enemy",
	"0x19 -- Blow open bonus wall (investigate)",
	"0x1A -- Shoot from cannon",
	"0x1B -- Kong in barrel",
	"0x1C -- Count down in bonus game",
	"0x1D -- Rattly jump",
	"0x1E -- More monkey sounds (unused?)",
	"0x1F -- Klinger sliding down",
	"0x20 -- Dixie loses life",
	"0x21 -- Blowing sound (unused?)",
	"0x22 -- Reveal token (unused?)",
	"0x23 -- Diddy juggling",
	"0x24 -- Neek squeak",
	"0x25 -- Blowing gum variant (unused?)",
	"0x26 -- Dixie blowing gum",
	"0x27 -- Collect kong letter pitch 1",
	"0x28 -- Collect kong letter pitch 2",
	"0x29 -- Collect kong letter pitch 3",
	"0x2A -- Collect kong letter pitch 4",
	"0x2B -- Lose life/ballon pop",
	"0x2C -- Gain life",
	"0x2D -- Collect coin",
	"0x2E -- K. Rool message",
	"0x2F -- Squawks attack",
	"0x30 -- Squawks flapping 1",
	"0x31 -- Squawks flapping 2",
	"0x32 -- Necky attacking",
	"0x33 -- Menu move",
	"0x34 -- Menu select",
	"0x35 -- Reveal token",
	"0x36 -- Collect token",
	"0x37 -- Klick Klack flipping over",
	"0x38 -- Collect life",
	"0x39 -- Krow ghost exploding twinkle",
	"0x3A -- Krow ghost exploding",
	"0x3B -- Zinger sound (unused?)",
	"0x3C -- Zinger sound higher pitch(unused?)",
	"0x3D -- Zinger buzzing",
	"0x3E -- Increase tempo/stop buzzing",
	"0x3F -- Flitter buzzing",
	"0x40 -- Team up",
	"0x41 -- Animal buddy destoryed by sign (used with 0x42, 0x43, 0x44)",
	"0x42 -- Animal buddy destoryed by sign (used with 0x41, 0x43, 0x44)",
	"0x43 -- Animal buddy destoryed by sign (used with 0x41, 0x42, 0x44)",
	"0x44 -- Animal buddy destoryed by sign (used with 0x41, 0x42, 0x43)",
	"0x45 -- Rattly hurt",
	"0x46 -- Squitter shoot web",
	"0x47 -- Squitter shooting platform",
	"0x48 -- Rattly idle jump",
	"0x49 -- Rattly high jump",
	"0x4A -- Load cannon ball into cannon",
	"0x4B -- Shoot cannon (From Kannon)",
	"0x4C -- Cannon ball falling from sky",
	"0x4D -- Squitter jump (investigate)",
	"0x4E -- Spiny walking",
	"0x4F -- Squawks hurt",
	"0x50 -- Invincible",
	"0x51 -- Hit Kruncha",
	"0x52 -- Rolling barrel",
	"0x53 -- Rambi headbutt",
	"0x54 -- Rambi trample",
	"0x55 -- Animal transformation sound (semi unused)",
	"0x56 -- Collect DK coin",
	"0x57 -- Necky dying",
	"0x58 -- Cat-O-9-Tails hurt",
	"0x59 -- Kudgel hurt",
	"0x5A -- K. Rool passing out",
	"0x5B -- K. Rool falling into water",
	"0x5C -- K. Rool falling into water (unused?)",
	"0x5D -- Krook jumped on",
	"0x5E -- Pause/unpause game",
	"0x5F -- Wrong/invalid selection",
	"0x60 -- Egg cracking sound",
	"0x61 -- Krow flapping",
	"0x62 -- Jumping in and out of water, or krow getting hit",
	"0x63 -- Clapper arf",
	"0x64 -- Krow grabbing egg",
	"0x65 -- Enguard jab, or egg falling",
	"0x66 -- Lost Enguard, Kleaver hooks",
	"0x67 -- Time running out in bonus",
	"0x68 -- Ambient in water",
	"0x69 -- Puft up inflating, Kleaver sinking",
	"0x6A -- Puft up exploding, Kleaver sinking 2",
	"0x6B -- Swimming, Kleaver vibrating, Race count down",
	"0x6C -- Shuri spinning, Kleaver boiling, Race go",
	"0x6D -- Clapper clap",
	"0x6E -- Jump on green kroc head/Klapper blowing",
	"0x6F -- Jump on brown kroc head",
	"0x70 -- Crashing mixed with DK (unused?)",
	"0x71 -- Deeper rambi head butt (unused?)",
	"0x72 -- Quieter monkey sound (unused?)",
	"0x73 -- Engaurd-like jab (unused?)",
	"0x74 -- Monkey sound (unused?)",
	"0x75 -- Weird monkey echo (Unused?)",
	"0x76 -- quieter monkey sound (unused?)",
	"0x77 -- Unknown",
	"0x78 -- Scared by boss",
	"0x79 -- Caw of Krow"
}

local sound_index = 0x0632
local sound_buffer = 0x0622
local effect_buffer = 0x0619
local spc_transfer_id = 0x00
local current_song = 0x1C
local stereo_flag = 0x1E

track(sound_buffer+0x00, 2)
track(sound_buffer+0x02, 2)
track(sound_buffer+0x04, 2)
track(sound_buffer+0x06, 2)
track(sound_buffer+0x08, 2)
track(sound_buffer+0x0A, 2)
track(sound_buffer+0x0C, 2)
track(sound_buffer+0x0E, 2)

local function display_sound()
	local sound_effect = clamp(slot, 0, 0x7F)		
	if play_sound_effect == true then
		write_word(sound_effect, 0x0619 + 10)
		write_word(sound_effect + 0x0500, 0x0622)
		write_word(0x00, sound_index)
		write_word(0x00, 0x0634)
		play_sound_effect = false
	end

	local sound_string = "Current index: %02X\n" ..
				"cmd 0(0x00): %04X\n" ..
				"cmd 1(0x02): %04X\n" ..
				"cmd 2(0x04): %04X\n" ..
				"cmd 3(0x06): %04X\n" ..
				"cmd 4(0x08): %04X\n" ..
				"cmd 5(0x0A): %04X\n" ..
				"cmd 6(0x0C): %04X\n" ..
				"cmd 7(0x0E): %04X\n" ..
				"sfx 0(0x00): %02X\n" ..
				"sfx 1(0x01): %02X\n" ..
				"sfx 2(0x02): %02X\n" ..
				"sfx 3(0x03): %02X\n" ..
				"sfx 4(0x04): %02X\n" ..
				"sfx 5(0x05): %02X\n" ..
				"sfx 6(0x06): %02X\n" ..
				"sfx 7(0x07): %02X\n" ..
				"sfx 8(0x08): %02X\n" ..
				"sfx 9(0x09): %02X\n" ..
				"sfx A(0x0A): %02X\n" ..
				"sfx B(0x0B): %02X\n" ..
				"sfx C(0x0C): %02X\n" ..
				"sfx D(0x0D): %02X\n" ..
				"sfx E(0x0E): %02X\n" ..
				"sfx F(0x0F): %02X\n\n" ..
				"SPC transfer id 0x%02X\n" ..
				"Current song 0x%04X\n" ..
				"Mono/Stereo 0x%02X\n\n" ..
				"Play sound effect: %s\n"
	
	text(0, 0, string.format(sound_string,
					read_word(sound_index),
					tracked_addresses[sound_buffer+0x00],
					tracked_addresses[sound_buffer+0x02],
					tracked_addresses[sound_buffer+0x04],
					tracked_addresses[sound_buffer+0x06],
					tracked_addresses[sound_buffer+0x08],
					tracked_addresses[sound_buffer+0x0A],
					tracked_addresses[sound_buffer+0x0C],
					tracked_addresses[sound_buffer+0x0E],
					read_byte(effect_buffer+0x00),
					read_byte(effect_buffer+0x01),
					read_byte(effect_buffer+0x02),
					read_byte(effect_buffer+0x03),
					read_byte(effect_buffer+0x04),
					read_byte(effect_buffer+0x05),
					read_byte(effect_buffer+0x06),
					read_byte(effect_buffer+0x07),
					read_byte(effect_buffer+0x08),
					read_byte(effect_buffer+0x09),
					read_byte(effect_buffer+0x0A),
					read_byte(effect_buffer+0x0B),
					read_byte(effect_buffer+0x0C),
					read_byte(effect_buffer+0x0D),
					read_byte(effect_buffer+0x0E),
					read_byte(effect_buffer+0x0F),
					read_byte(spc_transfer_id),
					read_byte(current_song),
					read_byte(stereo_flag),
					sound_effect_map[sound_effect+1]
				))
end

local camera_x = 0x17BA
local camera_unknown1 = 0x17BC
local camera_unknown2 = 0x17BE
local camera_y_inc = 0x17C0
local camera_y = 0x17C2
local camera_unknown3 = 0x17C4
local camera_unknown4 = 0x17C6
local camera_unknown5 = 0x17C8
local camera_last_update_x = 0x17CA
local camera_unknown6 = 0x17CC
local camera_last_update_y = 0x17CE

local tiledata_pointer = 0x0098
track(tiledata_pointer, 2)
track(tiledata_pointer+2, 1)

local function display_camera()
	local camera_string = "Camera X: %04X\n" ..
				"Camera unknown 1: %04X\n" ..
				"Camera unknown 2: %04X\n" ..
				"Camera Y inc: %04X\n" ..
				"Camera Y: %04X\n" ..
				"Camera unknown 3: %04X\n" ..
				"Camera unknown 4: %04X\n" ..
				"Camera unknown 5: %04X\n" ..
				"Camera last update X: %04X\n" ..
				"Camera unknown 6: %04X\n" ..
				"Camera last update Y: %04X\n" ..
				"Tiledata pointer: %02X%04X"
	
	text(0, 0, string.format(camera_string,
					read_word(camera_x),
					read_word(camera_unknown1),
					read_word(camera_unknown2),
					read_word(camera_y_inc),
					read_word(camera_y),
					read_word(camera_unknown3),
					read_word(camera_unknown4),
					read_word(camera_unknown5),
					read_word(camera_last_update_x),
					read_word(camera_unknown6),
					read_word(camera_last_update_y),
					tracked_addresses[tiledata_pointer+2], tracked_addresses[tiledata_pointer]
				))
end

local NMI = 0x0020
local game_loop = 0x0024
local game_mode_NMI = 0x0094
local game_mode = 0x0096

local function display_engine()
	local engine_string = "NMI: %04X\n" ..
				"game loop: %04X\n" ..
				"game mode NMI: %04X\n" ..
				"game mode: %04X"
	
	text(0, 0, string.format(engine_string,
					read_word(NMI),
					read_word(game_loop),
					read_word(game_mode_NMI),
					read_word(game_mode)
				))
end

local level = 0x00D3
local sprite_pointers = to_pc(0xFE0000)
local level_header = 0x0515

local function display_level()
	local level_id = read_word(level)
	local level_string = "level number: %04X\n" ..
				"Sprite data pointer: FF%04X\n\n" ..
				"LEVEL HEADER\n" ..
				"$0515 (0x00) Header: 0x%04X\n" ..
				"$0517 (0x02): 0x%04X\n" ..
				"$0519 (0x04): 0x%04X\n" ..
				"$051B (0x06): 0x%04X\n" ..
				"$051D (0x08): 0x%04X\n" ..
				"$051F (0x0A): 0x%04X\n" ..
				"$0521 (0x0C): 0x%04X\n" ..
				"$0523 (0x0E): 0x%04X\n" ..
				"$0525 (0x10): 0x%04X\n" ..
				"$0527 (0x12) NMI Pointer: 0x%04X\n" ..
				"$0529 (0x14) Level mode Pointer: 0x%04X\n" ..
				"$052B (0x16): 0x%04X\n" ..
				"$052D (0x18): 0x%04X\n" ..
				"$052F (0x1A): 0x%04X\n" ..
				"$0531 (0x1C): 0x%04X\n" ..
				"$0533 (0x1E) Spawn X position: 0x%04X\n" ..
				"$0535 (0x20) Spawn Y position: 0x%04X\n" ..
				"$0537 (0x22): 0x%04X\n" ..
				"$0539 (0x24): 0x%04X\n" ..
				"$053B (0x26): 0x%04X\n" ..
				"$053D (0x28) Exit 1: 0x%04X\n" ..
				"$053F (0x2A) Exit 2: 0x%04X\n" ..
				"$0541 (0x2C) Exit 3: 0x%04X\n" ..
				"$0543 (0x2E) Exit 4: 0x%04X\n" ..
				"$0545 (0x30) Exit 5: 0x%04X\n" ..
				"$0547 (0x32) Exit 6: 0x%04X\n" ..
				"$0549 (0x34) Exit 7: 0x%04X\n" ..
				"$054B (0x36) Exit 8: 0x%04X\n" ..
				"$054D (0x38) 0x%04X\n" ..
				"$0551 (0x3A): 0x%04X\n"
				
	text(0, 0, string.format(level_string,
					level_id,
					read_rom_word(sprite_pointers + level_id*2),
					read_word(level_header + 0x00),		--Level header
					read_word(level_header + 0x02),		--
					read_word(level_header + 0x04),		--
					read_word(level_header + 0x06),		--
					read_word(level_header + 0x08),		--
					read_word(level_header + 0x0A),		--
					read_word(level_header + 0x0C),		--
					read_word(level_header + 0x0E),		--
					read_word(level_header + 0x10),		--
					read_word(level_header + 0x12),		--NMI pointer
					read_word(level_header + 0x14),		--Level mode pointer
					read_word(level_header + 0x16),		--
					read_word(level_header + 0x18),		--
					read_word(level_header + 0x1A),		--
					read_word(level_header + 0x1C),		--
					read_word(level_header + 0x1E),		--
					read_word(level_header + 0x20),		--
					read_word(level_header + 0x22),		--
					read_word(level_header + 0x24),		--
					read_word(level_header + 0x26),		--
					read_word(level_header + 0x28),		--Exit 1
					read_word(level_header + 0x2A),		--Exit 2
					read_word(level_header + 0x2C),		--Exit 3
					read_word(level_header + 0x2E),		--Exit 4
					read_word(level_header + 0x30),		--Exit 5
					read_word(level_header + 0x32),		--Exit 6
					read_word(level_header + 0x34),		--Exit 7
					read_word(level_header + 0x36),		--Exit 8
					read_word(level_header + 0x38),		--
					read_word(level_header + 0x3A)		--
				))
end

local watched_addresses = {}
local function display_watch()
	local watch_string = ""
	
	for address, read_callback in pairs(watched_addresses) do 
		watch_string = watch_string .. read_callback()
	end
	
	text(0, 0, watch_string)
end

local keys = {}
keys.press = {}

function keys.register_keypress(key,fn)
	keys.press[key] = fn
	input.keyhook(key, true)
end


function on_keyhook(key, state)
	if keys.press[key] and (state.value == 1) then
		keys.press[key]()
	end
end

keys.register_keypress("equals", function() slot = slot + 1 ; gui.repaint() end)
keys.register_keypress("minus" , function() slot = slot - 1 ; gui.repaint() end)

keys.register_keypress("backquote" , function() show_debug = not show_debug ; gui.repaint() end)
keys.register_keypress("quotedbl" , function() show_dma_debug = not show_dma_debug end)

keys.register_keypress("p" , function() play_sound_effect = true end)

keys.register_keypress("1" , function() active_screen = sprite_screen ; gui.repaint() end)
keys.register_keypress("2" , function() active_screen = sound_screen ; gui.repaint() end)
keys.register_keypress("3" , function() active_screen = camera_screen ; gui.repaint() end)
keys.register_keypress("4" , function() active_screen = engine_screen ; gui.repaint() end)
keys.register_keypress("5" , function() active_screen = level_screen ; gui.repaint() end)
keys.register_keypress("6" , function() active_screen = watch_screen ; gui.repaint() end)

function on_paint(not_synth)
	if show_debug then
		if active_screen == sprite_screen then
			display_sprite()
		elseif active_screen == sound_screen then
			display_sound()
		elseif active_screen == camera_screen then
			display_camera()
		elseif active_screen == engine_screen then
			display_engine()
		elseif active_screen == level_screen then
			display_level()
		elseif active_screen == watch_screen then
			display_watch()
		end
	end
end

function on_dma(trigger_addr, source_addr, dest_addr, size, mode, dir, fixed)
	if not show_dma_debug then
		return
	end
	
	local exclusion_list = {
				0xB5D3DF, --OAM DMA
				0xB5A945 -- sprite DMA
				}
	for i, addr in pairs(exclusion_list) do
		if trigger_addr == addr then
			return
		end
	end
	
	--if trigger_addr == 0xBB8D0A then 
	if dest_addr == 0x18 and source_addr < 0x800000 then 
		local dma_string = "trigger: 0x%06X, source: 0x%06X, dest: 0x%02X, size: 0x%04X, mode: %d, dir: %d, fixed: %d"
		print(string.format(dma_string, trigger_addr, source_addr, dest_addr, size, mode, dir, fixed))
		dump_mmio()
		print("\n")
	end
end

function on_vm_reset()
	rom_restore_all()
end 


function dump_mmio()
	local layers_string = ""
	local layer_string = "Layer: %d, tilemap: 0x%04X, tiledata: 0x%04X, S: %d, X: 0x%04X, Y: 0x%04X\n"
	
	for i = 0, 3 do
		layers_string = layers_string .. string.format(layer_string,
									i+1,
									bg_register("scaddr", i),
									bg_register("tdaddr", i),
									bg_register("tilesize", i) == 1 and 8 or 16,
									bg_register("hofs", i),
									bg_register("vofs", i)
								)
	end
	local oam_string = string.format("OAM, base: 0x%04X, tiledata: 0x%04X, size: %d, table: %d, first: %d",
										register("ppu_oam_baseaddr"),
										register("ppu_oam_tdaddr"),
										register("ppu_oam_basesize"),
										register("ppu_oam_nameselect"),
										register("ppu_oam_firstsprite")
									)
	local mmio_string = "BG mode: %d\n" ..
				"VRAM addr: $%04X\n" ..
				layers_string ..
				oam_string
	print(string.format(mmio_string,
				register("ppu_bg_mode"),
				register("ppu_vram_addr")
			))
end

function dump_registers()
	local registers_string = "PC: %06X, A: %04X, X: %04X, Y: %04X"
	print(string.format(registers_string,
				register("pbpc"),
				register("a"),
				register("x"),
				register("y")
			))
end

function register_trace(address)
	if (type(address) == "table") then
		for i, trace in pairs(address) do
			memory2.ROM:registerexec(to_pc(trace), dump_registers)
		end
	else
		memory2.ROM:registerexec(to_pc(address), dump_registers)
	end
end

function unregister_trace(address)
	if (type(address) == "table") then
		for i, trace in pairs(address) do
			memory2.ROM:unregisterexec(to_pc(trace), dump_registers)
		end
	else
		memory2.ROM:unregisterexec(to_pc(address), dump_registers)
	end
end

function add_watch(name, address, size)
	if size == 1 then
		watched_addresses[address] = function() return string.format(name .. ": %02X\n", read_byte(address)) end
	elseif size == 2 then
		watched_addresses[address] = function() return string.format(name .. ": %04X\n", read_word(address)) end
	elseif size == 3 then
		watched_addresses[address] = function() return string.format(name .. ": %06X\n", read_long(address)) end
	elseif size >= 4 then
		watched_addresses[address] = function() return string.format(name .. ": %s\n", byte_table(address, 0, size)) end
	end
end

function delete_watch(address)
	watched_addresses = remove(watched_addresses, address)
end


--I personally don't want to use these in actual code for clarity reasons
--but on the fly I do want to type a lot less
--quick access calls for testing from the emulator lua console
--w = write, r = read (print), g = get(return)
--b = byte, w = word, l = long
function wl(value, offset)
	write_long(value, offset)
end

function ww(value, offset)
	write_word(value, offset)
end

function wb(value, offset)
	write_byte(value, offset)
end


function rl(offset)
	print(string.format("0x%06X", read_long(offset)))
end

function rw(offset)
	print(string.format("0x%04X", read_word(offset)))
end

function rb(offset)
	print(string.format("0x%02X", read_byte(offset)))
end

function gl(offset)
	return read_long(offset)
end

function gw(offset)
	return read_word(offset)
end

function gb(offset)
	return read_byte(offset)
end

function rrl(offset)
	return read_rom_long(offset)
end

function rrw(offset)
	return read_rom_word(offset)
end

function rrb(offset)
	return read_rom_byte(offset)
end

--rom quick access calls
function nop(address, size)
	write_rom_nop(address, size)
end

function zero(address, size)
	write_rom_zero(address, size)
end

function rtl(address)
	write_rom_byte_preserve(0x6B, address)
end

function rts(address, size)
	write_rom_byte_preserve(0x60, address)
end

function patch(address, data)
	write_rom_patch(address, data)
end

--print registers register stop
function stop(address)
	write_rom_stop(address)
end

function r(address)
	rom_restore(address)
end

function ra()
	rom_restore_all()
end

function pc(address)
	return to_pc(address)
end
