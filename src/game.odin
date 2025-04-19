package game

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os/os2"
import "core:strings"
import sdl3 "vendor:sdl3"
import ma "vendor:miniaudio"
import ttf "vendor:stb/truetype"
import img "vendor:stb/image"
breakpoint :: intrinsics.debug_trap

should_run := true

Game_Memory :: struct {
    ma_engine: ma.engine,
    ma_sound :ma.sound,
    sound_audio_filename: cstring,
    bpm: f32,
    fonts :[3]Font,
    sdl_renderer: ^sdl3.Renderer,
    sdl_window: ^sdl3.Window,
    animated_sprite_atlas: ^sdl3.Texture,
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

screen_width : i32 = 1280
screen_height : i32 = 720

media_player_buttons_sprite_width : f32 = 34
media_player_buttons_sprite_height : f32 = 33

Frame_Animation :: struct {
    frame_rate: f32,
    curr_frame: i32,
    ping_pong: bool,
    nb_frames: i32,
    timer: f32,
}

SpriteRow :: enum {play, pause, playhead, loop_on, loop_off}

animated_sprites := [SpriteRow]Frame_Animation {
    .play = {
        frame_rate = 7,
        nb_frames = 6,
    },
    .pause = {
        frame_rate = 7,
        nb_frames = 6,
    },
    .playhead = {
        frame_rate = 7,
        nb_frames = 3,
        ping_pong = true,
    },
    .loop_on = {
        frame_rate = 7,
        nb_frames = 6,
    },
    .loop_off = {
        frame_rate = 7,
        nb_frames = 8,
        ping_pong = true,
    },

}

sprite_atlas_src_rect_clip :: proc (texture: ^sdl3.Texture, row, col: i32, frame_width, frame_height: f32) -> sdl3.FRect {
    y := math.floor(f32(row) * frame_height)
    x := f32(col) * frame_width
    src := sdl3.FRect{x, y, frame_width, frame_height}
    return src
}

@(export)
game_init :: proc () {
    gmem = new(Game_Memory)


    sdl_init_ok := sdl3.CreateWindowAndRenderer("MiniAudio Demo", screen_width, screen_height, {}, &gmem.sdl_window, &gmem.sdl_renderer)
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

    // default_audio_filename := "C:\\Users\\johnb\\Music\\Full Moon Full Life (FULL VERSION LYRICS) _ Persona 3 Reload.mp3"
    default_audio_filename := "ASSETS/unlimited.mp3"
    // Note(johnb): all filenames are allocated with default allocator and then intented to be deleted before replacing
    // The reason is that currently, only one filename is really active at a time
    // in the future, i may display a bunch of filenames in the app in a library.
    // At that point, i will have all of those share the same lifetime.
    // In the more near future, i may try to pull song details like the track name, artist, or genre since
    // that is nice to display in a media player
    gmem.sound_audio_filename = strings.clone_to_cstring(default_audio_filename)

    sound_init_result := ma.sound_init_from_file(&gmem.ma_engine, gmem.sound_audio_filename, {.DECODE}, nil, nil, &gmem.ma_sound)
    if sound_init_result != .SUCCESS {
        fmt.printfln("[miniaudio] sound initialization from file failed")
        os2.exit(1)
    }

    sound_start_result := ma.sound_start(&gmem.ma_sound)
    if sound_start_result != .SUCCESS {
        fmt.printfln("[miniaudio] sound start failed")
    }
    gmem.bpm = 162

    x, y, channels_in_file: i32
    img_bytes := img.load("assets/MediaPlayerButtons.png", &x, &y, &channels_in_file, 4)
    surface := sdl3.CreateSurfaceFrom(x, y, .RGBA32, &img_bytes[0], x*channels_in_file)
    gmem.animated_sprite_atlas = sdl3.CreateTextureFromSurface(gmem.sdl_renderer, surface)
    // Note(jb1t): Do .NEAREST this so that:
    // 1. The sprites aren't blurry when scaled
    // 2. The sprite source clip doesn't bleed any pixels to a neighboring sprite. This happens if sprite clips are butted up to each other in the atlas.
    sdl3.SetTextureScaleMode(gmem.animated_sprite_atlas, .NEAREST)

    img.image_free(&img_bytes[0])
    sdl3.DestroySurface(surface)
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


file_dialogue_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
    is_no_file_selected := filelist[0] == nil
    if is_no_file_selected {
        return
    }
    ma.sound_uninit(&gmem.ma_sound)
    // Note(jblat): only one file will be in the list
    result := ma.sound_init_from_file(&gmem.ma_engine, filelist[0], {.DECODE}, nil, nil, &gmem.ma_sound)
    ma.sound_start(&gmem.ma_sound)

    // TODO(jblat): is this the best way to handle this type of error?
    context = context
    if result != .SUCCESS {
        result_description := ma.result_description(result)
        fmt.printfln("[miniaudio] sound failed to init from file: %s. result: %s", filelist[0], result_description)
        str := "audio file failed to load. try another file."
        delete(gmem.sound_audio_filename)
        gmem.sound_audio_filename = strings.clone_to_cstring(str)
        return
    }
    delete(gmem.sound_audio_filename)
    size_filename := len(filelist[0])
    cstr := make([]byte, size_filename + 1)
    gmem.sound_audio_filename = cstring(&cstr[0])
    mem.copy(rawptr(gmem.sound_audio_filename), rawptr(filelist[0]), size_filename)
}


@(export)
game_update :: proc () {
    seconds_in_minute : f32 = 60.0
    quarter_note_duration := seconds_in_minute / gmem.bpm

    sdl_event :sdl3.Event

    mem.copy(&prev_input_app_keys_is_down, &input_app_keys_is_down, size_of(input_app_keys_is_down))

    for sdl3.PollEvent(&sdl_event) {
        if sdl_event.type == .KEY_DOWN {
            // Note(jblat): Why mix sdl events and my input_app_keys_is_down code? Why not just use one or the other?
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

            is_loop_toggle_button_pressed := sdl_event.key.scancode == .L
            if is_loop_toggle_button_pressed {
                is_looping := ma.sound_is_looping(&gmem.ma_sound)
                ma.sound_set_looping(&gmem.ma_sound, !is_looping)
            }

            is_open_file_dialogue_button_pressed := sdl_event.key.scancode == .F
            if is_open_file_dialogue_button_pressed {
                file_filters := [?]sdl3.DialogFileFilter{
                    {name = "MP3 File",  pattern = "mp3"},
                    {name = "WAV File",  pattern = "wav"},
                    {name = "FLAC File", pattern = "flac"},
                }
                sdl3.ShowOpenFileDialog(file_dialogue_callback, nil, gmem.sdl_window, nil, 0, "C:\\Users\\johnb", false)
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

    font_size : f32 = 22
    line_spacing_scale : f32 = 1.1
    xpos : f32 = 1
    ypos : f32 = 1
    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 100, 0, 0, 255, gmem.fonts[1], "filename: %v", gmem.sound_audio_filename)
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
    top_padding_for_progress_bar : f32 = 10.0
    ypos += font_size * line_spacing_scale + top_padding_for_progress_bar

    { // progress bar
        padding_for_progress_bar : f32 = 100.0

        progress_bar_width := f32(screen_width) - (padding_for_progress_bar * 2.0)
        progress_bar_height : f32 = 27

        curr_time_in_sound_seconds : f32
        sound_length_seconds : f32
        ma.sound_get_cursor_in_seconds(&gmem.ma_sound, &curr_time_in_sound_seconds)
        ma.sound_get_length_in_seconds(&gmem.ma_sound, &sound_length_seconds)

        progress_scalar := curr_time_in_sound_seconds / sound_length_seconds
        past_progress_width := progress_bar_width * progress_scalar
        future_progress_width := progress_bar_width - past_progress_width

        progress_bar_xpos := xpos + padding_for_progress_bar
        future_progress_xpos := progress_bar_xpos + past_progress_width

        past_progress_bar_rectangle := sdl3.FRect{progress_bar_xpos, ypos, past_progress_width, progress_bar_height}
        future_progress_bar_rectangle := sdl3.FRect{future_progress_xpos, ypos, future_progress_width, progress_bar_height}

        sdl3.SetRenderDrawColor(gmem.sdl_renderer, 0,0,0,255)
        sdl3.RenderFillRect(gmem.sdl_renderer, &past_progress_bar_rectangle)

        sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
        sdl3.RenderFillRect(gmem.sdl_renderer, &future_progress_bar_rectangle)

        // playhead_sprite := animated_sprites[.playhead]
        playhead_sprite_dst := sdl3.FRect{
            future_progress_xpos - (media_player_buttons_sprite_width/2.0),
            ypos - 3,
            media_player_buttons_sprite_width,
            media_player_buttons_sprite_height,
        }
        playhead_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.playhead), animated_sprites[.playhead].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
        sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &playhead_sprite_src, &playhead_sprite_dst)

        if ma.sound_is_playing(&gmem.ma_sound) {
            play_sprite_dst := sdl3.FRect{ 10.0, ypos, media_player_buttons_sprite_width, media_player_buttons_sprite_height }
            play_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.play), animated_sprites[.play].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &play_sprite_src, &play_sprite_dst)
        } else {
            pause_sprite_dst := sdl3.FRect{ 10.0, ypos, media_player_buttons_sprite_width, media_player_buttons_sprite_height }
            pause_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.pause), animated_sprites[.pause].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &pause_sprite_src, &pause_sprite_dst)
        }

        if ma.sound_is_looping(&gmem.ma_sound) {

            loop_on_sprite_dst := sdl3.FRect{
                progress_bar_xpos + progress_bar_width + 10.0,
                ypos, media_player_buttons_sprite_width, media_player_buttons_sprite_height }
            loop_on_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.loop_on), animated_sprites[.loop_on].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &loop_on_sprite_src, &loop_on_sprite_dst)
        } else {
            loop_off_sprite_dst := sdl3.FRect{
                progress_bar_xpos + progress_bar_width + 10.0,
                ypos, media_player_buttons_sprite_width, media_player_buttons_sprite_height }
            loop_off_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.loop_off), animated_sprites[.loop_off].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &loop_off_sprite_src, &loop_off_sprite_dst)
        }
        ypos += progress_bar_height + padding_for_progress_bar
    }

    { // animated sprites
        for &animated_sprite in animated_sprites {
            animated_sprite.timer += f32(1.0/60.0)
            frame_duration_seconds : f32 = 1.0 / animated_sprite.frame_rate
            total_duration_seconds := frame_duration_seconds * f32(animated_sprite.nb_frames)
            nb_frames := animated_sprite.nb_frames
            if animated_sprite.ping_pong {
                total_duration_seconds *= 2
                nb_frames *= 2
            }
            if animated_sprite.timer >= total_duration_seconds {
                animated_sprite.timer = 0.0
            }
            curr_frame := i32(math.floor(animated_sprite.timer / frame_duration_seconds)) %% (nb_frames)
            if curr_frame >= animated_sprite.nb_frames {
                animated_sprite.curr_frame = (animated_sprite.nb_frames-1) - (curr_frame - animated_sprite.nb_frames)
            } else {
                animated_sprite.curr_frame = curr_frame
            }
        }
        width, height: f32
        sdl3.GetTextureSize(gmem.animated_sprite_atlas, &width, &height)
        for animated_sprite, sprite_row in animated_sprites {
            src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(sprite_row), animated_sprite.curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            dst := sdl3.FRect{xpos + (50.0*f32(sprite_row)), ypos, media_player_buttons_sprite_width * 2.0, media_player_buttons_sprite_height * 2.0}
            ypos += media_player_buttons_sprite_height + 10.0
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &src, &dst)
        }
    }

    sdl3.RenderPresent(gmem.sdl_renderer)
    free_all(context.temp_allocator)
    sdl3.Delay(u32(math.floor(f32(1000.0/60.0))))
}