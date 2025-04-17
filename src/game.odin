package game

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:os/os2"
import "core:mem"
import sdl3 "vendor:sdl3"
import ma "vendor:miniaudio"
import ttf "vendor:stb/truetype"

breakpoint :: intrinsics.debug_trap

should_run := true

Game_Memory :: struct {
    ma_engine: ma.engine,
    ma_sound :ma.sound,
    bpm: f32,
    fonts :[3]Font,
    sdl_renderer: ^sdl3.Renderer,
    sdl_window: ^sdl3.Window,
}

Font :: struct {
    font_packed_chars :[96]ttf.packedchar,
    font_line_height :f32,
    sdl_font_atlas_texture: ^sdl3.Texture,
}

gmem: ^Game_Memory

@(export)
game_memory_ptr :: proc() -> rawptr {
    return gmem
}

@(export)
game_memory_size :: proc() -> int {
    return size_of(Game_Memory)
}

Input_State :: enum {up, pressed, down, released}
Input_Command :: enum {play_toggle, force_hot_reload, force_build_and_hot_reload, force_restart, restart_sound}
Input_App_Key :: enum {Enter, LeftShift, RightShift, F5, F6, F7}

// INPUT_COMMAND_KEYMAP := [Input_App_Key] Input_Command {
//     .Enter = .play_toggle,
//     .RightShift = .restart_sound,
//     .F5 = .force_build_and_hot_reload,
//     .F6 = .force_hot_reload,
//     .F7 = .force_restart,
// }

// input_command_state := [Input_Command]Input_State {}

TTF_CHAR_AT_START : i32 :  32
TTF_CHAR_AMOUNT : i32 : 95
FONT_TEXTURE_SIDE_SIZE : i32 : 1024
FONT_TEXTURE_2D_SIZE : i32 : FONT_TEXTURE_SIDE_SIZE * FONT_TEXTURE_SIDE_SIZE

AUDIO_FILENAME :: "ASSETS/UNLIMITED.mp3"

font_init :: proc(font: ^Font, filename: string) {
    font.sdl_font_atlas_texture = sdl3.CreateTexture(gmem.sdl_renderer, .RGBA32, .STATIC, FONT_TEXTURE_SIDE_SIZE, FONT_TEXTURE_SIDE_SIZE)
    if font.sdl_font_atlas_texture == nil {
        fmt.printfln("[SDL3] Font texture failed to create")
        os2.exit(1)
    }

    sdl3.SetTextureBlendMode(font.sdl_font_atlas_texture, {.BLEND})
    { // load font as texture
        // font_file_data, err := os2.read_entire_file_from_path("assets/joystix monospace.otf", context.allocator)
        font_file_data, err := os2.read_entire_file_from_path(filename, context.allocator)

        defer delete(font_file_data)
        if err != nil {
            fmt.printfln("[stb_truetype] file failed to read")
            os2.exit(1)
        }

        bitmap := new([FONT_TEXTURE_2D_SIZE]byte)
        defer free(bitmap)
        pack_context : ttf.pack_context
        ttf.PackBegin(&pack_context, &bitmap[0], FONT_TEXTURE_SIDE_SIZE, FONT_TEXTURE_SIDE_SIZE, 0,1, nil)
        ttf.PackSetOversampling(&pack_context, 1, 1)
        some_arbitrary_size : f32 = 64.0
        font.font_line_height = some_arbitrary_size
        // scale := ttf.ScaleForPixelHeight()
        result := ttf.PackFontRange(&pack_context, &font_file_data[0], 0, font.font_line_height , TTF_CHAR_AT_START, TTF_CHAR_AMOUNT, &font.font_packed_chars[0])
        if result == 0 {
            fmt.printfln("[stb_truetype] pack font range failed")
            os2.exit(1)
        }
        ttf.PackEnd(&pack_context)

        pixels := make_slice([]u32, FONT_TEXTURE_2D_SIZE * size_of(u32))
        defer delete(pixels)
        sdl_pixel_format_details := sdl3.GetPixelFormatDetails(sdl3.PixelFormat.RGBA32)

        for i in 0 ..< FONT_TEXTURE_2D_SIZE {
            pixels[i] = sdl3.MapRGBA(sdl_pixel_format_details, nil, 0xFF, 0xFF, 0xFF, bitmap[i])
        }
        update_texture_ok := sdl3.UpdateTexture(font.sdl_font_atlas_texture, nil, &pixels[0], FONT_TEXTURE_SIDE_SIZE*size_of(u32))
        if !update_texture_ok {
            fmt.printfln("[SDL3] Font texture failed to udpate")
            os2.exit(1)
        }
    }
}

prev_keystate: [^]bool
keystate: [^]bool
nb_keys: i32

@(export)
game_init :: proc () {
    gmem = new(Game_Memory)


    sdl_init_ok := sdl3.CreateWindowAndRenderer("MiniAudio Demo", 1280, 720, {}, &gmem.sdl_window, &gmem.sdl_renderer)
    if !sdl_init_ok {
        fmt.printfln("[SDL3] Window and renderer failed to init")
        os2.exit(1)
    }


    ma_init_result := ma.engine_init(nil, &gmem.ma_engine)
    if ma_init_result != .SUCCESS {
        fmt.printfln("[miniaudio] ma engine init failure")
        os2.exit(1)
    }

    font_init(&gmem.fonts[0], "assets/CHECKBK0.TTF")
    font_init(&gmem.fonts[1], "assets/joystix monospace.otf")
    font_init(&gmem.fonts[2], "assets/VCR_OSD_MONO.ttf")

    sound_init_result := ma.sound_init_from_file(&gmem.ma_engine, AUDIO_FILENAME, {.DECODE}, nil, nil, &gmem.ma_sound)
    if sound_init_result != .SUCCESS {
        fmt.printfln("[miniaudio] sound initialization from file failed")
        os2.exit(1)
    }

    sound_start_result := ma.sound_start(&gmem.ma_sound)
    if sound_start_result != .SUCCESS {
        fmt.printfln("[miniaudio] sound start failed")
    }

    sdl3.PumpEvents()
    keystate := sdl3.GetKeyboardState(&nb_keys)
    prev_keystate = make([^]bool, nb_keys)
    mem.copy(&prev_keystate[0], &keystate[0], size_of(bool) * int(nb_keys))
    gmem.bpm = 162

}

@(export)
game_init_window :: proc () {}


@(export)
game_hot_reloaded :: proc(mem: rawptr) {
    gmem = (^Game_Memory)(mem)
}

@(export)
game_force_reload :: proc() -> bool {
    return input_app_keys_is_down[.F5]
}

@(export)
game_force_build_and_reload :: proc() -> bool {
    return input_app_keys_is_down[.F6]
}

@(export)
game_force_restart :: proc() -> bool {
    return input_app_keys_is_down[.F7]
}

track: mem.Tracking_Allocator
temp_track: mem.Tracking_Allocator


@(export)
game_shutdown :: proc() {
    when ODIN_DEBUG {
        if len(track.bad_free_array) > 0 {
            for entry in track.bad_free_array {
                fmt.eprintf(
                    "%v bad free at %v\n",
                    entry.location,
                    entry.memory,
                )
            }
        }
        if len(temp_track.allocation_map) > 0 {
            for _, entry in temp_track.allocation_map {
                fmt.eprintf(
                    "temp_allocator %v leaked %v bytes\n",
                    entry.location,
                    entry.size,
                )
            }
        }
        if len(temp_track.bad_free_array) > 0 {
            for entry in temp_track.bad_free_array {
                fmt.eprintf(
                    "temp_allocator %v bad free at %v\n",
                    entry.location,
                    entry.memory,
                )
            }
        }
        mem.tracking_allocator_destroy(&track)
        mem.tracking_allocator_destroy(&temp_track)
    }
}

@(export)
game_shutdown_window :: proc() {}


@(export)
game_should_run :: proc() -> bool {
    // Never run this proc in browser. It contains a 16 ms sleep on web!
    when ODIN_OS != .JS {
		return should_run
	}
	return true
}

render_text :: proc (renderer: ^sdl3.Renderer, x, y, size: f32, r, g, b, a: u8, font: Font, text: string) {
    sdl3.SetTextureColorMod(font.sdl_font_atlas_texture, r, g, b)
    sdl3.SetTextureAlphaMod(font.sdl_font_atlas_texture, a)
    xpos : f32 = x
    font_size : f32 = size
    font_scale := font_size / font.font_line_height
    ypos : f32 = y

    for i in 0..<len(text) {
        if i32(text[i]) >= TTF_CHAR_AT_START && i32(text[i]) < TTF_CHAR_AT_START + TTF_CHAR_AMOUNT + 1 {
            info := font.font_packed_chars[i32(text[i]) - TTF_CHAR_AT_START]
            src := sdl3.FRect{f32(info.x0), f32(info.y0), f32(info.x1) - f32(info.x0), f32(info.y1) - f32(info.y0)}
            font_scale := font_size / font.font_line_height
            dst := sdl3.FRect{
                xpos + f32(info.xoff) * font_scale,
                (ypos + f32(info.yoff) * font_scale) + font_size,
                f32(info.x1 - info.x0) * font_scale,
                f32(info.y1 - info.y0) * font_scale,
            }


            sdl3.RenderTexture(renderer, font.sdl_font_atlas_texture, &src, &dst)
            // sdl3.SetRenderDrawColor(renderer, r, g, b, a)
            // sdl3.RenderRect(renderer, &dst)

            xpos += f32(info.xadvance) * font_scale
        }
    }
}

render_text_tprintf :: proc (renderer: ^sdl3.Renderer, x, y, size: f32, r, g, b, a: u8, font: Font, fstring: string, v: ..any) {
    text := fmt.tprintf(fstring, ..v)
    render_text(renderer, x, y, size, r, g, b, a, font, text)
}

input_app_keys_is_down := [Input_App_Key]bool{}
prev_input_app_keys_is_down := [Input_App_Key]bool{}

ma_seek_quarter_notes :: proc (quarter_note_duration, nb_quarter_notes: f32) {
    seconds : f32
    ma.sound_get_cursor_in_seconds(&gmem.ma_sound, &seconds)
    curr_quarter_note := seconds / quarter_note_duration
    seek_quarter_note := curr_quarter_note + nb_quarter_notes
    seek_quarter_note_timestamp_seconds := seek_quarter_note * quarter_note_duration
    sample_rate :u32
    ma.data_source_get_data_format(gmem.ma_sound.pDataSource, nil, nil, &sample_rate, nil, 0)
    frame_index := u64(seek_quarter_note_timestamp_seconds * f32(sample_rate))
    ma.sound_seek_to_pcm_frame(&gmem.ma_sound, frame_index)
}

@(export)
game_update :: proc () {
    seconds_in_minute : f32 = 60.0
    quarter_note_duration := seconds_in_minute / gmem.bpm

    sdl_event :sdl3.Event

    mem.copy(&prev_input_app_keys_is_down, &input_app_keys_is_down, size_of(input_app_keys_is_down))

    for sdl3.PollEvent(&sdl_event) {
        if sdl_event.type == .KEY_DOWN {
            // Note(jb1t): Why mix sdl events and my input_app_keys_is_down code? Why not just use one or the other?
            // If a user is holding a key, SDL will keep sending KEYDOWN events after like half a second. This is common
            // for things like text editing. In this app, when seeking forwards and backwards, i want that behavior.
            // Since SDL already does that, i use it in addition to code i have for tracking if an input is already down
            // That way we can have key chord type shortcuts WITH the sdl behavior
            if sdl_event.key.scancode == .RETURN {
                input_app_keys_is_down[.Enter] = true
            } else if sdl_event.key.scancode == .LSHIFT {
                input_app_keys_is_down[.LeftShift] = true
            }
            else if sdl_event.key.scancode == .RSHIFT {
                ma.sound_seek_to_pcm_frame(&gmem.ma_sound, 0)
                ma.sound_start(&gmem.ma_sound)
            }
            else if sdl_event.key.scancode == .RIGHT && !input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, 1.0)
            }
            else if sdl_event.key.scancode == .LEFT && !input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, -1.0)
            }

            if sdl_event.key.scancode == .RIGHT && input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, 4.0)
            }
            else if sdl_event.key.scancode == .LEFT && input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, -4.0)
            }
        }
        else if sdl_event.type == .KEY_UP {
            if sdl_event.key.scancode == .RETURN {
                input_app_keys_is_down[.Enter] = false
            } else if sdl_event.key.scancode == .LSHIFT {
                input_app_keys_is_down[.LeftShift] = false
            }
        }

        if sdl_event.type == .WINDOW_CLOSE_REQUESTED {
            should_run = false
            return
        }
    }


    is_return_key_down := input_app_keys_is_down[.Enter] == true
    is_return_key_down_last_frame := prev_input_app_keys_is_down[.Enter] == true
    is_return_key_pressed := is_return_key_down && !is_return_key_down_last_frame
    if is_return_key_pressed {
        if ma.sound_is_playing(&gmem.ma_sound) {
            ma.sound_stop(&gmem.ma_sound)
        } else {
            ma.sound_start(&gmem.ma_sound)
        }
    }


    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 120, 100, 0, 255)
    sdl3.RenderClear(gmem.sdl_renderer)

    font_size : f32 = 32
    line_spacing_scale : f32 = 1
    xpos : f32 = 1
    ypos : f32 = 1
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 100, 0, 0, 255, gmem.fonts[1], "filename: %v", AUDIO_FILENAME)
    ypos += font_size * line_spacing_scale

    seconds : f32
    length : f32
    ma.sound_get_cursor_in_seconds(&gmem.ma_sound, &seconds)
    ma.sound_get_length_in_seconds(&gmem.ma_sound, &length)
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 0, 0, 0, 255, gmem.fonts[1], "seconds: %.4f / %.4f", seconds, length)
    ypos += font_size * line_spacing_scale

    curr_pcm_frame : u64
    length_in_pcm_frames : u64
    ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &curr_pcm_frame)
    ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &length_in_pcm_frames)
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 30, 30, 30, 255, gmem.fonts[1], "pcm frames: %d / %d", curr_pcm_frame, length_in_pcm_frames)
    ypos += font_size * line_spacing_scale

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 75, 75, 75, 255, gmem.fonts[1], "bpm: %.2f", gmem.bpm)
    ypos += font_size * line_spacing_scale


    curr_beat := i32(seconds * (gmem.bpm / seconds_in_minute))
    total_beats := i32(length * (gmem.bpm / seconds_in_minute))
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 50, 50, 50, 255, gmem.fonts[1], "beats: %d / %d", curr_beat, total_beats)
    ypos += font_size * line_spacing_scale

    beats_in_measure : i32 : 4
    curr_measure := curr_beat / beats_in_measure
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 75, 75, 75, 255, gmem.fonts[1], "measure: %d", curr_measure)
    ypos += font_size * line_spacing_scale

    render_text(gmem.sdl_renderer, xpos, ypos, font_size, 200, 200, 0, 255, gmem.fonts[1], "metronome: ")
    beat_in_measure := curr_beat %% beats_in_measure
    for i in 0..<beat_in_measure+1 {
        spacing : f32 = 10
        size := font_size
        beat_x := xpos + 250 + f32(i)*(size + spacing)
        r := sdl3.FRect{beat_x, ypos, size, size}
        sdl3.SetRenderDrawColor(gmem.sdl_renderer, 0,0,0,255)
        sdl3.RenderFillRect(gmem.sdl_renderer, &r)
    }

    sdl3.RenderPresent(gmem.sdl_renderer)
    free_all(context.temp_allocator)
    sdl3.Delay(u32(1/60))
}