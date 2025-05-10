package game

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os/os2"
import "core:strings"
import "core:strconv"
import "core:path/filepath"
import "core:slice"
import "base:runtime"
import vmem "core:mem/virtual"
import sa "core:container/small_array"
import sdl3 "vendor:sdl3"
import ma "vendor:miniaudio"
import ttf "vendor:stb/truetype"
import img "vendor:stb/image"
breakpoint :: intrinsics.debug_trap

should_run := true

Game_Memory :: struct {
    ma_engine  : ma.engine,
    ma_sound   : ma.sound,
    ma_decoder : ma.decoder,
    // Note(johb): Although this is called pcm_frames, this is a copy of a fully decoded
    // audio stream, so really, each index is a sample. It's called that, cause its what miniaudio calls it.
    // A call to ma.sound_get_cursor_in_pcm_frames will need to be scaled by number of channels
    // to get index into this array
    // TODO(johnb): Want to make this dynamic eventually. When we do that, will need to keep it either
    // threadsafe, or ensure that it is only ever cleared in the main thread serially
    pcm_frames: [100_600_000]f32, // 10 minutes worth of 2-channel audio at 48Khz/sec
    nb_pcm_frames: u64,
    waveform_samples: [1024*10]f32,
    frames_per_waveform_peak: u64,
    current_filename_index: int,
    current_directory_audio_filenames_arena: vmem.Arena,
    current_directory_audio_filenames: sa.Small_Array(64, cstring),
    bpm: f32,
    offset: f32,
    fonts :[3]Font,
    sdl_renderer: ^sdl3.Renderer,
    sdl_window: ^sdl3.Window,
    animated_sprite_atlas: ^sdl3.Texture,

    // UI STATE
    // bpm_digit_buffer         : [5]int,
    selected_bpm_digit       : int,
    // offset_digit_buffer      : [6]int,
    selected_offset_digit    : int,
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
Input_App_Key :: enum {Enter, LeftShift, RightShift, LeftCtrl, F5, F6, F7, B, V, S, O}

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

screen_width : i32 = 1920
screen_height : i32 = 1080

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

/*
    Notes for "Adding silence before the track, or starting some time in the track":

    Might be useful for making sure a beat is aligned on the 0th second of the song.

    Useful for the metronome, and current beat and measure displays

    There is basic support for scheduling the starting and stopping of nodes. You can only schedule one
    start and one stop at a time. This is mainly intended for putting nodes into a started or stopped
    state in a frame-exact manner. Without this mechanism, starting and stopping of a node is limited
    to the resolution of a call to `ma_node_graph_read_pcm_frames()` which would typically be in blocks
    of several milliseconds. The following APIs can be used for scheduling node states:

        ```c
        ma_node_set_state_time()
        ma_node_get_state_time()
        ```

    The time is absolute and must be based on the global clock. An example is below:

        ```c
        ma_node_set_state_time(&myNode, ma_node_state_started, sampleRate*1);   // Delay starting to 1 second.
        ma_node_set_state_time(&myNode, ma_node_state_stopped, sampleRate*5);   // Delay stopping to 5 seconds.
        ```

    An example for changing the state using a relative time.

        ```c
        ma_node_set_state_time(&myNode, ma_node_state_started, sampleRate*1 + ma_node_graph_get_time(&myNodeGraph));
        ma_node_set_state_time(&myNode, ma_node_state_stopped, sampleRate*5 + ma_node_graph_get_time(&myNodeGraph));
        ```

    Note that due to the nature of multi-threading the times may not be 100% exact. If this is an
    issue, consider scheduling state changes from within a processing callback. An idea might be to
    have some kind of passthrough trigger node that is used specifically for tracking time and handling
    events.

*/


@(export)
game_init :: proc () {
    // TODO(johnb): Setup tracking allocator in here. Make it separate from the hot reload app. The reason is that hopefully we
    // can allocate stuff with the tracking allocator in the C proc, as i currently think calling an allocating function directly
    // from the C proc won't involve any re-organization of the logic if we want a tracking allcator
    gmem = new(Game_Memory)


    sdl_init_ok := sdl3.CreateWindowAndRenderer("MiniAudio Demo", screen_width, screen_height,{.RESIZABLE}, &gmem.sdl_window, &gmem.sdl_renderer)
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

    arena_alloc_error := vmem.arena_init_growing(&gmem.current_directory_audio_filenames_arena)
    if arena_alloc_error != nil {
        fmt.printfln("[core:mem/virtual] arena alloc error: %v", arena_alloc_error)
        os2.exit(1)
    }

    when ODIN_DEBUG {
        default_allocator := context.allocator
        mem.tracking_allocator_init(&track, default_allocator)
        context.allocator = mem.tracking_allocator(&track)
    }

    default_audio_filename : cstring = "C:\\Users\\johnb\\Music\\Imogen Heap - Speak For Yourself (Deluxe Version)\\Imogen Heap - Speak For Yourself (Deluxe Version) - 10 I Am In Love With You.wav"
    { // populate the direcotry array
        current_filepath_str := strings.clone_from_cstring(default_audio_filename, context.temp_allocator)
        directory_of_selected_song := filepath.dir(current_filepath_str, context.temp_allocator)
        files_in_dir, err := os2.read_directory_by_path(directory_of_selected_song, sa.cap(gmem.current_directory_audio_filenames), context.temp_allocator)
        if err != nil {
            fmt.printfln("[os/os2]: Error generating directory list: %v", err)
        }
        vmem.arena_free_all(&gmem.current_directory_audio_filenames_arena)
        for path_info, idx in files_in_dir {
            path := path_info.fullpath
            fmt.printfln("path: %v", path)
            if os2.is_dir(path) {
                continue
            }
            ext := filepath.ext(path)
            supported_audio_extensions := [?]string{".mp3", ".wav", ".flac"}
            _, is_supported_audio_extension := slice.linear_search(supported_audio_extensions[:], ext)
            if !is_supported_audio_extension {
                continue
            }
            if path == string(default_audio_filename) {
                gmem.current_filename_index = idx
            }
            arena_allocator := vmem.arena_allocator(&gmem.current_directory_audio_filenames_arena)
            path_cstring := strings.clone_to_cstring(path, arena_allocator)
            sa.append_elem(&gmem.current_directory_audio_filenames, path_cstring)
        }
    }

    result := reinit_sound_decoder_and_waveform_from_file(default_audio_filename)
    if result != .SUCCESS {
        fmt.printfln("[miniaudio] sound initialization from file failed")
        os2.exit(1)
    }

    gmem.bpm = 136
    gmem.offset = 0.16

    // gmem.bpm_digit_buffer   = { 1, 3, 6, 0, 0 }
    gmem.selected_bpm_digit       = 2
    // gmem.offset_digit_buffer     = {0, 0, 0, 1, 6, 0}
    gmem.selected_offset_digit    = 3

    x, y, channels_in_file: i32
    img_bytes := img.load("assets/MediaPlayerButtons.png", &x, &y, &channels_in_file, 4)
    surface := sdl3.CreateSurfaceFrom(x, y, .RGBA32, &img_bytes[0], x*channels_in_file)
    gmem.animated_sprite_atlas = sdl3.CreateTextureFromSurface(gmem.sdl_renderer, surface)
    // Note(johnb): Do .NEAREST this so that:
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


render_sprite_clip_from_atlas :: proc (renderer: ^sdl3.Renderer, atlas: ^sdl3.Texture, row, col: i32, frame_width, frame_height, dstx, dsty, dst_scale: f32) {
    dst := sdl3.FRect {dstx, dsty, frame_width * dst_scale, frame_height * dst_scale}
    src := sprite_atlas_src_rect_clip(atlas, row, col, frame_width, frame_height)
    sdl3.RenderTexture(renderer, atlas, &src, &dst)

}

reinit_sound_decoder_and_waveform_from_file :: proc(filename: cstring ) -> ma.result {

    // if gmem.pcm_frames != nil {
    //     free(gmem.pcm_frames)
    // }
    is_looping := ma.sound_is_looping(&gmem.ma_sound)
    ma.sound_uninit(&gmem.ma_sound)
    // Note(jblat): only one file will be in the list
    result := ma.sound_init_from_file(&gmem.ma_engine, filename, {.DECODE}, nil, nil, &gmem.ma_sound)
    // ma.sound_start(&gmem.ma_sound)
    ma.sound_set_looping(&gmem.ma_sound, is_looping)


    { // replace the decoder and generate waveform visualization
        ma.decoder_uninit(&gmem.ma_decoder)

        ma_decoder_config := ma.decoder_config_init(ma.format.f32, 2,  gmem.ma_engine.sampleRate)
        result := ma.decoder_init_file(filename, &ma_decoder_config, &gmem.ma_decoder)
        total_pcm_frames: u64
        ma.decoder_get_length_in_pcm_frames(&gmem.ma_decoder, &total_pcm_frames)

        sample_rate := gmem.ma_decoder.outputSampleRate

        total_samples := total_pcm_frames * u64(gmem.ma_decoder.outputChannels)

        read_pcm_frames_result := ma.decoder_read_pcm_frames(&gmem.ma_decoder, &gmem.pcm_frames[0], total_pcm_frames, &gmem.nb_pcm_frames)
        if read_pcm_frames_result != .SUCCESS {
            fmt.printfln("[miniaudio] read pcm frames failed: %v", read_pcm_frames_result)
        }
        gmem.frames_per_waveform_peak = gmem.nb_pcm_frames / len(gmem.waveform_samples)
        samples_per_peak := gmem.frames_per_waveform_peak * u64(gmem.ma_decoder.outputChannels)

        for peak, peak_index in gmem.waveform_samples {
            peak_max : f32 = 0.0
            peak_min : f32 = 0.0
            for i in 0..<samples_per_peak {
                sample_index := peak_index * int(samples_per_peak) + int(i)
                sample := gmem.pcm_frames[sample_index]
                if sample > peak_max {
                    peak_max = sample
                } else if sample < peak_min {
                    peak_min = sample
                }
            }
            if peak_max > math.abs(peak_min) {
                gmem.waveform_samples[peak_index] = peak_max
            } else {
                gmem.waveform_samples[peak_index] = peak_min
            }
        }
    }

    return ma.result.SUCCESS
}

set_input_state :: proc(scancode : sdl3.Scancode, val : bool) {
    // Note(jblat): Why mix sdl events and my input_app_keys_is_down code? Why not just use one or the other?
    // If a user is holding a key, SDL will keep sending KEYDOWN events after like half a second. This is common
    // for things like text editing. In this app, when seeking forwards and backwards, i want that behavior.
    // Since SDL already does that, i use it in addition to code i have for tracking if an input is already down
    // That way we can have key chord type shortcuts WITH the sdl behavior
    if scancode == .RETURN {
        input_app_keys_is_down[.Enter] = val
    }
    else if scancode == .LSHIFT {
        input_app_keys_is_down[.LeftShift] = val
    }
    else if scancode == .LCTRL {
        input_app_keys_is_down[.LeftCtrl] = val
    }
    else if scancode == .B {
        input_app_keys_is_down[.B] = val
    }
    else if scancode == .V {
        input_app_keys_is_down[.V] = val
    }
    else if scancode == .S {
        input_app_keys_is_down[.S] = val
    }
    else if scancode == .O {
        input_app_keys_is_down[.O] = val
    }
}

digit_buffer :: proc (buffer : []int, selected_digit : ^int, scancode : sdl3.Scancode) {
    move_modifying_digit_right_scancode_pressed := scancode == .RIGHT
    move_modifying_digit_left_scancode_pressed  := scancode == .LEFT
    increase_digit_value_scancode_pressed       := scancode == .UP
    decrease_digit_value_scancode_pressed       := scancode == .DOWN

    move_modifiable_digit_right := move_modifying_digit_right_scancode_pressed
    move_modifiable_digit_left  := move_modifying_digit_left_scancode_pressed
    increase_digit              := increase_digit_value_scancode_pressed
    decrease_digit              := decrease_digit_value_scancode_pressed

    if move_modifiable_digit_right {
        selected_digit^ += 1
        selected_digit^ = selected_digit^ %% len(buffer)
    }

    if move_modifiable_digit_left {
        selected_digit^ -= 1
        selected_digit^ = selected_digit^ %% len(buffer)
    }

    if increase_digit {
        buffer[selected_digit^] += 1
        if selected_digit^ != 0 {
            if buffer[selected_digit^] >= 10 {
                higher_digit := selected_digit^ - 1
                buffer[higher_digit] += 1
                buffer[higher_digit] = buffer[higher_digit] %% 10
            }
        }
        buffer[selected_digit^] = buffer[selected_digit^] %% 10
    }

    if decrease_digit {
        buffer[selected_digit^] -= 1
        if selected_digit^ != 0 {
            if buffer[selected_digit^] <= 0 {
                higher_digit := selected_digit^ - 1
                buffer[higher_digit] -= 1
                buffer[higher_digit] = buffer[higher_digit] %% 10
                buffer[selected_digit^] = 9
            }
        }
        buffer[selected_digit^] = buffer[selected_digit^] %% 10
    }
}


power_of_ten_digit_adjust :: proc (val: ^f32, power_of_ten : ^int, hi, lo : int, scancode : sdl3.Scancode) {
    move_modifying_digit_right_scancode_pressed := scancode == .RIGHT
    move_modifying_digit_left_scancode_pressed  := scancode == .LEFT
    increase_digit_value_scancode_pressed       := scancode == .UP
    decrease_digit_value_scancode_pressed       := scancode == .DOWN

    move_modifiable_digit_right := move_modifying_digit_right_scancode_pressed
    move_modifiable_digit_left  := move_modifying_digit_left_scancode_pressed
    increase_digit              := increase_digit_value_scancode_pressed
    decrease_digit              := decrease_digit_value_scancode_pressed

    if move_modifiable_digit_right {
        power_of_ten^ -= 1
        power_of_ten^ = math.clamp(power_of_ten^, lo, hi)
    }

    if move_modifiable_digit_left {
        power_of_ten^ += 1
        power_of_ten^ = math.clamp(power_of_ten^, lo, hi)
    }

    amount_to_change := math.pow10(f32(power_of_ten^))

    if increase_digit {
        val^ += amount_to_change
    }
    if decrease_digit {
        val^ -= amount_to_change
    }

    // this will look like 9.99 or 999.99. You get the idea.
    max_val := f32(math.pow(10, f32(hi+1)) - 1) + f32(math.pow(10, f32(math.abs(lo))) - 1) / math.pow(10, f32(math.abs(lo)))

    val^ = math.clamp(val^, 0, max_val)

}

//%07.3f
render_highlight_digit_f32 :: proc(val: f32, x_offset, y_offset, font_size: f32, font: Font, label: string, nb_digits, nb_decimals, selected_digit: int) {
    fmt_string := fmt.tprintf("%%0%d.%df", nb_digits, nb_decimals)
    bpm_text := fmt.tprintf(fmt_string, val)
    font_scale := font_size / font.font_line_height
    a := int(math.log10(f32(math.abs(val)))) + 1
    nb_int_digits := a < nb_digits - 1- nb_decimals ? nb_digits - 1 - nb_decimals : a
    bpm_int_part_str := fmt.tprintf("%03d", int(val))
    // nb_int_digits := len(bpm_int_part_str)
    char_index := nb_int_digits - 1 - selected_digit

    if char_index >= nb_int_digits {
        char_index += 1 // account for the '.'
    }

    highlight_rect := sdl3.FRect{}
    xpos : f32 = x_offset
    for i in 0..<len(bpm_text) {
        if i32(bpm_text[i]) >= TTF_CHAR_AT_START && i32(bpm_text[i]) < TTF_CHAR_AT_START + TTF_CHAR_AMOUNT + 1 {
            info := font.font_packed_chars[i32(bpm_text[i]) - TTF_CHAR_AT_START]
            src := sdl3.FRect{f32(info.x0), f32(info.y0), f32(info.x1) - f32(info.x0), f32(info.y1) - f32(info.y0)}
            highlight_rect = sdl3.FRect{
                xpos + f32(info.xoff) * font_scale,
                (y_offset + f32(info.yoff) * font_scale) + font_size,
                f32(info.x1 - info.x0) * font_scale,
                f32(info.y1 - info.y0) * font_scale,
            }

            xpos += f32(info.xadvance) * font_scale
            if i == char_index {
                break
            }
        }
    }

    render_text_length : f32 = 0
    for i in 0..<len(label) {
        if i32(label[i]) >= TTF_CHAR_AT_START && i32(label[i]) < TTF_CHAR_AT_START + TTF_CHAR_AMOUNT + 1 {
            info := font.font_packed_chars[i32(label[i]) - TTF_CHAR_AT_START]
            src := sdl3.FRect{f32(info.x0), f32(info.y0), f32(info.x1) - f32(info.x0), f32(info.y1) - f32(info.y0)}
            render_text_length += f32(info.xadvance) * font_scale
        }
    }

    highlight_rect.x += render_text_length + x_offset
    highlight_rect.x -= 1
    highlight_rect.y -= 1
    highlight_rect.w += 2
    highlight_rect.h += 2

    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
    sdl3.RenderFillRect(gmem.sdl_renderer, &highlight_rect)
}

@(export)
game_update :: proc () {
    @(static) should_draw_table        := false
    @(static) should_draw_weird_visual := false
    @(static) modify_bpm_mode          := false


    req_go_to_next_track := false
    req_go_to_prev_track := false
    update_time_start := sdl3.GetTicks()
    actual_screen_width, actual_screen_height: i32
    sdl3.GetWindowSize(gmem.sdl_window, &screen_width, &screen_height)
    scale_width := f32(actual_screen_width) / f32(screen_width)
    scale_height := f32(actual_screen_height) / f32(screen_height)

    // sdl3.SetRenderScale(gmem.sdl_renderer, scale_width, scale_height)
    seconds_in_minute : f32 = 60.0
    quarter_note_duration := seconds_in_minute / gmem.bpm

    sdl_event :sdl3.Event

    mem.copy(&prev_input_app_keys_is_down, &input_app_keys_is_down, size_of(input_app_keys_is_down))

    for sdl3.PollEvent(&sdl_event) {
        if sdl_event.type == .KEY_DOWN
        {
            set_input_state(sdl_event.key.scancode, true)

            seek_quarter_note_button_held := input_app_keys_is_down[.S]
            seek_measure_button_held := input_app_keys_is_down[.LeftShift]

            if sdl_event.key.scancode == .RSHIFT {
                ma.sound_seek_to_pcm_frame(&gmem.ma_sound, 0)
                ma.sound_start(&gmem.ma_sound)
            }
            else if sdl_event.key.scancode == .RIGHT && !seek_measure_button_held && seek_quarter_note_button_held {
                ma_seek_quarter_notes(quarter_note_duration, 1.0)
            }
            else if sdl_event.key.scancode == .LEFT && !seek_measure_button_held && seek_quarter_note_button_held{
                ma_seek_quarter_notes(quarter_note_duration, -1.0)
            }

            if sdl_event.key.scancode == .RIGHT && input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, 4.0)
            }
            else if sdl_event.key.scancode == .LEFT && input_app_keys_is_down[.LeftShift] {
                ma_seek_quarter_notes(quarter_note_duration, -4.0)
            }

            if sdl_event.key.scancode == .RIGHT && input_app_keys_is_down[.LeftCtrl] {
                req_go_to_next_track = true
            } else if sdl_event.key.scancode == .LEFT && input_app_keys_is_down[.LeftCtrl]{
                req_go_to_prev_track = true
            }

            modify_bpm_button_held := input_app_keys_is_down[.B]
            if modify_bpm_button_held {
                power_of_ten_digit_adjust(&gmem.bpm, &gmem.selected_bpm_digit, 2,-2, sdl_event.key.scancode)
            }

            modify_offset_button_held := input_app_keys_is_down[.O]
            if modify_offset_button_held {
                power_of_ten_digit_adjust(&gmem.offset, &gmem.selected_offset_digit, 2,-3, sdl_event.key.scancode)
            }

            is_volume_modify_button_held := input_app_keys_is_down[.V]
            is_volume_up_button_pressed := sdl_event.key.scancode == .UP
            increase_volume := is_volume_modify_button_held && is_volume_up_button_pressed
            if increase_volume {
                curr_volume := ma.engine_get_volume(&gmem.ma_engine)
                new_volume := curr_volume + 0.1
                new_volume = min(1.0, new_volume)
                result := ma.engine_set_volume(&gmem.ma_engine, new_volume)
                if result != .SUCCESS {
                    fmt.printfln("[miniaudio] volume did not get set correctly: %v", result)
                }
            }

            is_volume_down_button_presesd := sdl_event.key.scancode == .DOWN
            decrease_volume := is_volume_modify_button_held && is_volume_down_button_presesd
            if decrease_volume {
                curr_volume := ma.engine_get_volume(&gmem.ma_engine)
                new_volume := curr_volume - 0.1
                result := ma.engine_set_volume(&gmem.ma_engine, new_volume)
                if result != .SUCCESS {
                    fmt.printfln("[miniaudio] volume did not get set correctly: %v", result)
                }
            }

            is_loop_toggle_button_pressed := sdl_event.key.scancode == .L
            if is_loop_toggle_button_pressed {
                is_looping := ma.sound_is_looping(&gmem.ma_sound)
                ma.sound_set_looping(&gmem.ma_sound, !is_looping)
            }

            is_show_table_toggle_button_pressed := sdl_event.key.scancode == .T
            if is_show_table_toggle_button_pressed {
                should_draw_table = !should_draw_table
            }

            is_show_weird_visual_toggle_button_pressed := sdl_event.key.scancode == .W
            if is_show_weird_visual_toggle_button_pressed {
                should_draw_weird_visual = !should_draw_weird_visual
            }

            is_open_file_dialogue_button_pressed := sdl_event.key.scancode == .F
            if is_open_file_dialogue_button_pressed {

                file_dialogue_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
                    context = context
                    context.allocator = mem.tracking_allocator(&track)

                    { // back out
                        is_no_file_selected := filelist[0] == nil
                        if is_no_file_selected {
                            return
                        }
                    }

                    { // reinit stuff
                        result := reinit_sound_decoder_and_waveform_from_file(filelist[0])
                        // TODO(jblat): is this the best way to handle this type of error?
                        if result != .SUCCESS {
                            result_description := ma.result_description(result)
                            fmt.printfln("[miniaudio] sound failed to init from file: %s. result: %s", filelist[0], result_description)
                            str := "audio file failed to load: "
                            // TODO(johnb): Actually do something useful, like show some kind of message
                            return
                        }
                        ma.sound_start(&gmem.ma_sound)
                    }


                    { // populate the directory array
                        directory_of_selected_song := filepath.dir(string(filelist[0]), context.temp_allocator)
                        files_in_dir, err := os2.read_directory_by_path(directory_of_selected_song, sa.cap(gmem.current_directory_audio_filenames), context.temp_allocator)
                        if err != nil {
                            fmt.printfln("[os/os2]: Error generating directory list: %v", err)
                        }

                        vmem.arena_free_all(&gmem.current_directory_audio_filenames_arena)
                        sa.clear(&gmem.current_directory_audio_filenames)

                        for path_info in files_in_dir {
                            path := path_info.fullpath
                            fmt.printfln("path: %v", path)
                            if os2.is_dir(path) {
                                continue
                            }
                            ext := filepath.ext(path)
                            supported_audio_extensions := [?]string{".mp3", ".wav", ".flac"}
                            _, is_supported_audio_extension := slice.linear_search(supported_audio_extensions[:], ext)
                            if !is_supported_audio_extension {
                                continue
                            }

                            arena_allocator := vmem.arena_allocator(&gmem.current_directory_audio_filenames_arena)
                            path_cstring := strings.clone_to_cstring(path, arena_allocator)
                            sa.append_elem(&gmem.current_directory_audio_filenames, path_cstring)
                            idx := sa.len(gmem.current_directory_audio_filenames) - 1
                            if path == string(filelist[0]) {
                                gmem.current_filename_index = idx
                            }
                        }
                    }
                }

                file_filters := [?]sdl3.DialogFileFilter{
                    {name = "Supported Audio Files", pattern = "mp3;wav;flac"},
                    {name = "MP3 File",  pattern = "mp3"},
                    {name = "WAV File",  pattern = "wav"},
                    {name = "FLAC File", pattern = "flac"},
                }

                sdl3.ShowOpenFileDialog(file_dialogue_callback, nil, gmem.sdl_window, &file_filters[0], len(file_filters), "C:\\Users\\", false)
            }
        }
        else if sdl_event.type == .KEY_UP
        {
            set_input_state(sdl_event.key.scancode, false)
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

    // { // convert bpm buffer to bpm float
    //     integer_part := gmem.bpm_digit_buffer[0]*100 + gmem.bpm_digit_buffer[1]*10 + gmem.bpm_digit_buffer[2]
    //     decimal_part := gmem.bpm_digit_buffer[3]*10 + gmem.bpm_digit_buffer[4]
    //     gmem.bpm = f32(integer_part) + f32(decimal_part)/100.0
    // }

    // { // convert offset buffer to offset float
    //     integer_part := gmem.offset_digit_buffer[0]*100 + gmem.offset_digit_buffer[1]*10 + gmem.offset_digit_buffer[2]
    //     decimal_part := gmem.offset_digit_buffer[3]*100 + gmem.offset_digit_buffer[4]*10 + gmem.offset_digit_buffer[5]
    //     gmem.offset = f32(integer_part) + f32(decimal_part)/1000.0
    // }

    { // handle going to next or prev song
        is_sound_finished := gmem.ma_sound.atEnd
        go_to_next_track := is_sound_finished || req_go_to_next_track
        if go_to_next_track {
            gmem.current_filename_index = (gmem.current_filename_index + 1) %% gmem.current_directory_audio_filenames.len
            curr_filename := sa.get(gmem.current_directory_audio_filenames, gmem.current_filename_index)
            result := reinit_sound_decoder_and_waveform_from_file(curr_filename)
            if result != .SUCCESS {
                fmt.printfln("[miniaudio] failed reinit %v", result)
            }
            ma.sound_start(&gmem.ma_sound)
        }

        go_to_prev_track := req_go_to_prev_track
        if go_to_prev_track {
            gmem.current_filename_index = (gmem.current_filename_index - 1) %% gmem.current_directory_audio_filenames.len
            curr_filename := sa.get(gmem.current_directory_audio_filenames, gmem.current_filename_index)
            result := reinit_sound_decoder_and_waveform_from_file(curr_filename)
            if result != .SUCCESS {
                fmt.printfln("[miniaudio] failed reinit %v", result)
            }
            ma.sound_start(&gmem.ma_sound)
        }
    }

    { // animated sprites update
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
    }

    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 120, 100, 0, 255)
    sdl3.RenderClear(gmem.sdl_renderer)

    font_size : f32 = 24
    line_spacing_scale : f32 = 1.1
    xpos : f32 = 1
    ypos : f32 = 1
    current_audio_filename := sa.get(gmem.current_directory_audio_filenames, gmem.current_filename_index)

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 100, 0, 0, 255, gmem.fonts[1], "filename: %v", current_audio_filename)
    ypos += font_size * line_spacing_scale

    curr_cursor_seconds : f32
    length : f32
    ma.sound_get_cursor_in_seconds(&gmem.ma_sound, &curr_cursor_seconds)
    ma.sound_get_length_in_seconds(&gmem.ma_sound, &length)

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 0, 0, 0, 255, gmem.fonts[1], "seconds: %.4f / %.4f", curr_cursor_seconds, length)
    ypos += font_size * line_spacing_scale

    curr_pcm_frame : u64
    length_in_pcm_frames : u64
    ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &curr_pcm_frame)
    ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &length_in_pcm_frames)

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 30, 30, 30, 255, gmem.fonts[1], "pcm frames: %d / %d", curr_pcm_frame, length_in_pcm_frames)
    ypos += font_size * line_spacing_scale

    is_bpm_modify_button_held := input_app_keys_is_down[.B]
    if is_bpm_modify_button_held {
        render_highlight_digit_f32(gmem.bpm, xpos, ypos, font_size, gmem.fonts[1], "bpm: ", 6, 2, gmem.selected_bpm_digit)
    }

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 75, 75, 75, 255, gmem.fonts[1], "bpm: %06.2f", gmem.bpm)
    ypos += font_size * line_spacing_scale

    is_offset_modify_button_held := input_app_keys_is_down[.O]
    if is_offset_modify_button_held {
        render_highlight_digit_f32(gmem.offset, xpos, ypos, font_size, gmem.fonts[1], "offset: ", 7, 3, gmem.selected_offset_digit)
    }

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 75, 75, 75, 255, gmem.fonts[1], "offset: %07.3f", gmem.offset)
    ypos += font_size * line_spacing_scale

    curr_beat := i32( gmem.offset + (curr_cursor_seconds * (gmem.bpm / seconds_in_minute) ) )
    total_beats := i32(gmem.offset + (length * (gmem.bpm / seconds_in_minute)) )

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 50, 50, 50, 255, gmem.fonts[1], "beats: %d / %d", curr_beat, total_beats)
    ypos += font_size * line_spacing_scale

    beats_in_measure : i32 : 4
    curr_measure := curr_beat / beats_in_measure
    total_measures := total_beats / 4

    render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 75, 75, 75, 255, gmem.fonts[1], "measure: %d / %d", curr_measure, total_measures)
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
    ypos += font_size * line_spacing_scale

    { // volume
        volume := ma.engine_get_volume(&gmem.ma_engine)
        volume_0_to_10 := i32(math.round(volume * 10))
        render_text_tprintf(gmem.sdl_renderer, xpos, ypos, font_size, 0,0,0,255, gmem.fonts[1], "volume: %f", volume)
        for i in 0..<volume_0_to_10 {
            spacing : f32 = 10
            size := font_size
            volume_x := xpos + 250 + f32(i)*(size + spacing)
            r := sdl3.FRect{volume_x, ypos, size, size}
            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
            sdl3.RenderFillRect(gmem.sdl_renderer, &r)
        }
        for i in volume_0_to_10..<10 {
            spacing : f32 = 10
            size := font_size
            volume_x := xpos + 250 + f32(i)*(size + spacing)
            r := sdl3.FRect{volume_x, ypos, size, size}
            sdl3.SetRenderDrawBlendMode(gmem.sdl_renderer, {.BLEND})
            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,100)
            sdl3.RenderFillRect(gmem.sdl_renderer, &r)
        }

        ypos += font_size * line_spacing_scale
    }


    { // progress bar
        top_padding_for_progress_bar : f32 = 10.0
        ypos += top_padding_for_progress_bar

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

        for measure in 0..<total_measures {
            measure_duration := quarter_note_duration*4 // only 4/4
            measure_start_ts := gmem.offset + (f32(measure) * measure_duration)
            measure_start_progress := measure_start_ts / sound_length_seconds
            measure_start_x := xpos + padding_for_progress_bar + (progress_bar_width * measure_start_progress)
            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 150,150,150,255)
            sdl3.RenderLine(gmem.sdl_renderer, measure_start_x, ypos, measure_start_x, ypos + progress_bar_height)
        }

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
                ypos,
                media_player_buttons_sprite_width,
                media_player_buttons_sprite_height
            }
            loop_on_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.loop_on), animated_sprites[.loop_on].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &loop_on_sprite_src, &loop_on_sprite_dst)
        } else {
            loop_off_sprite_dst := sdl3.FRect{
                progress_bar_xpos + progress_bar_width + 10.0,
                ypos,
                media_player_buttons_sprite_width,
                media_player_buttons_sprite_height
            }
            loop_off_sprite_src := sprite_atlas_src_rect_clip(gmem.animated_sprite_atlas, i32(SpriteRow.loop_off), animated_sprites[.loop_off].curr_frame, media_player_buttons_sprite_width, media_player_buttons_sprite_height)
            sdl3.RenderTexture(gmem.sdl_renderer, gmem.animated_sprite_atlas, &loop_off_sprite_src, &loop_off_sprite_dst)
        }
        ypos += progress_bar_height + top_padding_for_progress_bar
    }


    panel_layout_row_height : f32 = 500.0
    panel_layout_col_width : f32 = f32(screen_width) / 2
    panel_layout_at_x : f32 = 0
    panel_layout_at_y : f32 = ypos

    max_panel_row_height : f32 = 0
    if should_draw_table { // draw table
        column_names := [?]string{"PCM Frame", "Left Sample", "Right Sample"}

        font_size : f32 = 20.0
        font_padding : f32 = 1.5

        table_layout_row_height := font_size * font_padding
        table_layout_col_width := panel_layout_col_width / len(column_names)
        table_layout_at_y : f32 = panel_layout_at_y
        table_layout_at_x : f32 = panel_layout_at_x

        for column_name, column_index in column_names {
            render_text(gmem.sdl_renderer, table_layout_at_x, table_layout_at_y, font_size, 255,255,255,255, gmem.fonts[1], column_name)
            r := sdl3.FRect {table_layout_at_x, table_layout_at_y, table_layout_col_width, table_layout_row_height}
            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
            sdl3.RenderRect(gmem.sdl_renderer, &r)

            table_layout_at_x += table_layout_col_width
        }

        // next row
        table_layout_at_x = panel_layout_at_x
        table_layout_at_y += table_layout_row_height

        current_pcm_cursor : u64
        ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_cursor)

        total_samples := gmem.nb_pcm_frames * u64(gmem.ma_decoder.outputChannels)
        start_pcm_frame_index := current_pcm_cursor * u64(gmem.ma_decoder.outputChannels)
        start_pcm_frame_index = clamp(start_pcm_frame_index, 0, total_samples)

        // end_pcm_frame_index := start_pcm_frame_index + (u64(nb_rows_to_display) * u64(gmem.ma_decoder.outputChannels))
        // end_pcm_frame_index = clamp(end_pcm_frame_index, 0, total_samples)

        // TODO(johnb): This only works for 2 channel stereo audio
        // Need to modify so that its dynamic based on number of channels
        // there will be NChannels + 1 Columns to be displayed. The extra column is for the frame index

        // I think there's really just:
        // - mono: Sample
        // - stero: Left Sample, Right Sample
        // - 5.1  : Front Left, Front Right, Surround Left, Surround Right, Center Front
        for pcm_frame_index := start_pcm_frame_index; table_layout_at_y < panel_layout_at_y + (panel_layout_row_height-table_layout_row_height); pcm_frame_index += 2 {
            if pcm_frame_index >= total_samples {
                break
            }
            left_sample := gmem.pcm_frames[pcm_frame_index]
            right_sample := gmem.pcm_frames[pcm_frame_index + 1]

            pcm_frame := pcm_frame_index / u64(gmem.ma_decoder.outputChannels)
            pcm_frame_index_as_text := fmt.tprintf("%d", pcm_frame)
            left_sample_as_text := fmt.tprintf("%f", left_sample)
            right_sample_as_text := fmt.tprintf("%f", right_sample)

            column_values := [3]string{pcm_frame_index_as_text, left_sample_as_text, right_sample_as_text}
            for val, column_idx in column_values {
                render_text(gmem.sdl_renderer, table_layout_at_x, table_layout_at_y, font_size, 255,255,255,255, gmem.fonts[1], val)
                r := sdl3.FRect {table_layout_at_x, table_layout_at_y, table_layout_col_width, table_layout_row_height}
                sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
                sdl3.RenderRect(gmem.sdl_renderer, &r)

                // next column
                table_layout_at_x += table_layout_col_width
            }

            // next row
            table_layout_at_x = panel_layout_at_x
            table_layout_at_y += table_layout_row_height
        }
    }

    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 150,150,150,255)
    panel_rect := sdl3.FRect{xpos, ypos, panel_layout_col_width, panel_layout_row_height}
    sdl3.RenderRect(gmem.sdl_renderer, &panel_rect)


    // next column
    panel_layout_at_x += panel_layout_col_width

    { // draw non-absolute pcm frames as waveform
        current_pcm_cursor : u64
        ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_cursor)
        nb_samples_to_display : f32 = 200
        total_samples := gmem.nb_pcm_frames * u64(gmem.ma_decoder.outputChannels)
        start_pcm_frame_index := current_pcm_cursor * u64(gmem.ma_decoder.outputChannels)
        start_pcm_frame_index = clamp(start_pcm_frame_index, 0, total_samples)
        end_pcm_frame_index := start_pcm_frame_index + (u64(nb_samples_to_display) * u64(gmem.ma_decoder.outputChannels))
        end_pcm_frame_index = clamp(end_pcm_frame_index, 0, total_samples)

        wave_max_absolute_height_in_either_direction : f32 = 200.0

        panel_mid_y := panel_layout_at_y + wave_max_absolute_height_in_either_direction/2.0

        spacing : f32 = panel_layout_col_width / nb_samples_to_display
        offset : f32 = 0.0
        for pcm_frame_index := start_pcm_frame_index; pcm_frame_index < end_pcm_frame_index; pcm_frame_index += 2 {
            offset += 1.0
            xpos : f32 = panel_layout_at_x + offset * spacing
            next_xpos := panel_layout_at_x + (offset+1)*spacing

            left_sample := gmem.pcm_frames[pcm_frame_index]
            next_left_sample := gmem.pcm_frames[pcm_frame_index+2]
            left_y1 := panel_mid_y + (wave_max_absolute_height_in_either_direction / 2.0 - (left_sample*2) * (wave_max_absolute_height_in_either_direction/2.0))
            next_left_y2 := panel_mid_y + (wave_max_absolute_height_in_either_direction / 2.0 - (next_left_sample*2) * (wave_max_absolute_height_in_either_direction/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 0,182,252,255)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, left_y1, next_xpos, next_left_y2)

            right_sample := gmem.pcm_frames[pcm_frame_index+1]
            next_right_sample := gmem.pcm_frames[pcm_frame_index+3]
            right_y1 := panel_mid_y + (wave_max_absolute_height_in_either_direction / 2.0 - (right_sample*2) * (wave_max_absolute_height_in_either_direction/2.0))
            next_right_y2 := panel_mid_y + (wave_max_absolute_height_in_either_direction / 2.0 - (next_right_sample*2) * (wave_max_absolute_height_in_either_direction/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 252,191,0,255)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, right_y1, next_xpos, next_right_y2)
        }
    }

    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 150,150,150,255)
    non_absolute_pcm_frame_waveform_panel_rect := sdl3.FRect{panel_layout_at_x, panel_layout_at_y, panel_layout_col_width, panel_layout_row_height}
    sdl3.RenderRect(gmem.sdl_renderer, &non_absolute_pcm_frame_waveform_panel_rect)

    // next panel row
    panel_layout_at_x = 0
    panel_layout_at_y += panel_layout_row_height

    // change dimension
    panel_layout_row_height = 120.0


    { // draw full waveform non-absolute
        waveform_width : i32 = i32(panel_layout_col_width)
        wave_max_height : f32 = panel_layout_row_height

        y_midpoint := panel_layout_at_y

        nb_waveform_indices_in_visualization := waveform_width
        current_pcm_frame: u64
        ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_frame)
        total_pcm_frames: u64
        ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &total_pcm_frames)

        nb_seconds_to_display : f32 = 15.0
        current_cursor_seconds_ts : f32
        ma.sound_get_cursor_in_seconds(&gmem.ma_sound, &current_cursor_seconds_ts)

        nb_channels := ma.engine_get_channels(&gmem.ma_engine)

        nb_samples_per_second :=  u64(gmem.ma_engine.sampleRate) * u64(nb_channels)
        nb_frames_per_second := gmem.ma_engine.sampleRate
        nb_seconds_per_peak_bucket : f32 = f32(gmem.frames_per_waveform_peak) /  f32(nb_frames_per_second)  
        peak_bucket_duration_in_seconds := nb_seconds_per_peak_bucket

        nb_peak_buckets_to_display := nb_seconds_to_display / peak_bucket_duration_in_seconds

        peak_bucket_spacing := panel_layout_col_width / nb_peak_buckets_to_display

        current_waveform_index := (current_pcm_frame) / (gmem.frames_per_waveform_peak )
        current_waveform_index = clamp(current_waveform_index, 0, len(gmem.waveform_samples))
        end_waveform_index := current_waveform_index + u64(nb_peak_buckets_to_display)
        end_waveform_index = clamp(end_waveform_index, 0, len(gmem.waveform_samples))

        for i, offset in current_waveform_index..<end_waveform_index {
            xpos := f32(i32(offset))*peak_bucket_spacing
            next_xpos :=  f32(i32(offset+1))*peak_bucket_spacing
            peak := gmem.waveform_samples[i]
            if i + 1 >= len(gmem.waveform_samples) {
                break // gtfo
            }
            next_peak := gmem.waveform_samples[i+1]
            y1 := y_midpoint + (wave_max_height / 2.0 - peak * (wave_max_height/2.0))
            next_y2 := y_midpoint + (wave_max_height / 2.0 - next_peak * (wave_max_height/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,150,255,255)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
        }

        measure_duration := quarter_note_duration*4 // only 4/4
        next_measure_ts := f32(curr_measure + 1) * measure_duration
        time_until_next_measure := next_measure_ts - curr_cursor_seconds
        space_before_next_measure := (panel_layout_col_width / nb_seconds_to_display) * time_until_next_measure
        nb_measures_to_display := nb_seconds_to_display / measure_duration
        end_measure := i32(f32(curr_measure) + (nb_measures_to_display))
        end_measure = clamp(end_measure, 0, total_measures)
        measure_spacing := panel_layout_col_width / nb_measures_to_display

        for i, offset in curr_measure..<end_measure+1 {
            xpos := space_before_next_measure + f32(i32(offset))*measure_spacing
            if xpos > panel_layout_at_x + panel_layout_col_width {
                break
            }
            sdl3.SetRenderDrawColor(gmem.sdl_renderer, 200,200,200,255)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, panel_layout_at_y, xpos, panel_layout_at_y + panel_layout_row_height)
        }
    }

    sdl3.SetRenderDrawColor(gmem.sdl_renderer, 150,150,150,255)
    r := sdl3.FRect{panel_layout_at_x, panel_layout_at_y, panel_layout_col_width, panel_layout_row_height}
    sdl3.RenderRect(gmem.sdl_renderer, &r)

    if should_draw_weird_visual { // Draw cool and weird visual
        ypos : f32 = 240
        waveform_padding : i32 = 20
        waveform_width : i32 = 300
        wave_max_height : f32 = 300.0

        nb_waveform_indices_in_visualization := 20
        current_pcm_frame: u64
        ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_frame)
        total_pcm_frames: u64
        ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &total_pcm_frames)
        current_waveform_index := (current_pcm_frame) / (gmem.frames_per_waveform_peak )
        current_waveform_index = clamp(current_waveform_index, 0, len(gmem.waveform_samples))
        end_waveform_index := current_waveform_index + u64(nb_waveform_indices_in_visualization/2)
        end_waveform_index = clamp(end_waveform_index, 0, len(gmem.waveform_samples))

        color := [4]u8{0,0,0,255}
        index_x_spacing :=  waveform_width /  i32(nb_waveform_indices_in_visualization) // lol i have no idea
        for i, offset in current_waveform_index..<end_waveform_index {
            xpos := f32(waveform_padding) + f32(waveform_width*2) - f32(index_x_spacing*i32(offset))
            next_xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset+1))
            peak := gmem.waveform_samples[i]
            if i + 1 >= len(gmem.waveform_samples) {
                break // gtfo
            }
            next_peak := gmem.waveform_samples[i+1]
            y1 := ypos + (wave_max_height / 2.0 - (peak*2) * (wave_max_height/2.0))
            next_y2 := ypos + (wave_max_height / 2.0 - (next_peak*2) * (wave_max_height/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, color.r,color.g,color.b,color.a)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
        }

        for i, offset in current_waveform_index..<end_waveform_index {
            xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset))
            next_xpos := f32(waveform_padding) + f32(waveform_width*2)- f32(index_x_spacing*i32(offset+1))
            peak := -gmem.waveform_samples[i]
            if i + 1 >= len(gmem.waveform_samples) {
                break // gtfo
            }
            next_peak := gmem.waveform_samples[i+1]
            y1 := ypos + (wave_max_height / 2.0 - (peak*2) * (wave_max_height/2.0))
            next_y2 := ypos + (wave_max_height / 2.0 - (next_peak*2) * (wave_max_height/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, color.r,color.g,color.b,color.a)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
        }

        for i, offset in current_waveform_index..<end_waveform_index {
            xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset))
            next_xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset+1))
            peak := gmem.waveform_samples[i]
            if i + 1 >= len(gmem.waveform_samples) {
                break // gtfo
            }
            next_peak := gmem.waveform_samples[i+1]
            y1 := ypos + (wave_max_height / 2.0 - (peak*2) * (wave_max_height/2.0))
            next_y2 := ypos + (wave_max_height / 2.0 - (next_peak*2) * (wave_max_height/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, color.r,color.g,color.b,color.a)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
        }

        for i, offset in current_waveform_index..<end_waveform_index {
            xpos := f32(waveform_padding) +  f32(waveform_width*2) - f32(index_x_spacing*i32(offset))
            next_xpos := f32(waveform_padding)+  f32(waveform_width*2) - f32(index_x_spacing*i32(offset+1))
            peak := gmem.waveform_samples[i]
            if i + 1 >= len(gmem.waveform_samples) {
                break // gtfo
            }
            next_peak := gmem.waveform_samples[i+1]
            y1 := ypos + (wave_max_height / 2.0 - (peak*2) * (wave_max_height/2.0))
            next_y2 := ypos + (wave_max_height / 2.0 - (next_peak*2) * (wave_max_height/2.0))

            sdl3.SetRenderDrawColor(gmem.sdl_renderer, color.r,color.g,color.b,color.a)
            sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
        }

        ypos += wave_max_height + 10.0
    }

    // { // Draw cool and weird 3d like visual
    //     waveform_padding : i32 = 400
    //     waveform_width : i32 = screen_width - waveform_padding*2
    //     wave_max_height : f32 = 120.0

    //     nb_waveform_indices_in_visualization := 20
    //     current_pcm_frame: u64
    //     ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_frame)
    //     total_pcm_frames: u64
    //     ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &total_pcm_frames)
    //     current_waveform_index := (current_pcm_frame) / (gmem.frames_per_waveform_peak )
    //     current_waveform_index = clamp(current_waveform_index, 0, len(gmem.waveform_samples))
    //     end_waveform_index := current_waveform_index + u64(nb_waveform_indices_in_visualization/2)
    //     end_waveform_index = clamp(end_waveform_index, 0, len(gmem.waveform_samples))

    //     index_x_spacing :=  waveform_width /  i32(nb_waveform_indices_in_visualization) // lol i have no idea
    //     for i, offset in current_waveform_index..<end_waveform_index {
    //         xpos := f32(waveform_padding) + f32(waveform_width*2) - f32(index_x_spacing*i32(offset))
    //         next_xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset+1))
    //         peak := gmem.waveform_samples[i]
    //         if i + 1 >= len(gmem.waveform_samples) {
    //             break // gtfo
    //         }
    //         next_peak := gmem.waveform_samples[i+1]
    //         y1 := ypos + (wave_max_height / 2.0 - peak * (wave_max_height/2.0))
    //         next_y2 := ypos + (wave_max_height / 2.0 - next_peak * (wave_max_height/2.0))

    //         sdl3.SetRenderDrawColor(gmem.sdl_renderer, 150,150,255,255)
    //         sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
    //     }

    //     for i, offset in current_waveform_index..<end_waveform_index {
    //         xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset))
    //         next_xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset+1))
    //         peak := gmem.waveform_samples[i]
    //         if i + 1 >= len(gmem.waveform_samples) {
    //             break // gtfo
    //         }
    //         next_peak := gmem.waveform_samples[i+1]
    //         y1 := ypos + (wave_max_height / 2.0 - peak * (wave_max_height/2.0))
    //         next_y2 := ypos + (wave_max_height / 2.0 - next_peak * (wave_max_height/2.0))

    //         sdl3.SetRenderDrawColor(gmem.sdl_renderer, 255,255,255,255)
    //         sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
    //     }

    //     ypos += wave_max_height + 10.0
    // }

    // { // Try to draw osciliscopy waveform
    //     waveform_padding : i32 = 500
    //     waveform_width : i32 = screen_width - waveform_padding*2
    //     wave_max_height : f32 = 120.0

    //     nb_waveform_indices_in_visualization := 40
    //     current_pcm_frame: u64
    //     ma.sound_get_cursor_in_pcm_frames(&gmem.ma_sound, &current_pcm_frame)
    //     total_pcm_frames: u64
    //     ma.sound_get_length_in_pcm_frames(&gmem.ma_sound, &total_pcm_frames)

    //     current_waveform_index := (current_pcm_frame) / (gmem.frames_per_waveform_peak )
    //     current_waveform_index = clamp(current_waveform_index, 0, len(gmem.waveform_samples))
    //     begin_waveform_index := current_waveform_index - u64(nb_waveform_indices_in_visualization/2)
    //     begin_waveform_index = clamp(begin_waveform_index, 0, len(gmem.waveform_samples))

    //     index_x_spacing :=  waveform_width /  i32(nb_waveform_indices_in_visualization) // lol i have no idea

    //     for i, offset in begin_waveform_index..<current_waveform_index {
    //         xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset))
    //         next_xpos := f32(waveform_padding) + f32(index_x_spacing*i32(offset+1))
    //         peak := gmem.waveform_samples[i]
    //         if i + 1 >= len(gmem.waveform_samples) {
    //             break // gtfo
    //         }
    //         next_peak := gmem.waveform_samples[i+1]
    //         y1 := ypos + (wave_max_height / 2.0 - peak * (wave_max_height/2.0))
    //         next_y2 := ypos + (wave_max_height / 2.0 - next_peak * (wave_max_height/2.0))

    //         sdl3.SetRenderDrawColor(gmem.sdl_renderer, 100,255,100,255)
    //         sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
    //     }

    //     for i, offset in begin_waveform_index..<current_waveform_index {
    //         xpos := f32(waveform_padding) + f32(waveform_width) - f32(index_x_spacing*i32(offset))
    //         next_xpos := f32(waveform_padding) + f32(waveform_width) - f32(index_x_spacing*i32(offset+1))
    //         peak := gmem.waveform_samples[i]
    //         if i + 1 >= len(gmem.waveform_samples) {
    //             break // gtfo
    //         }
    //         next_peak := gmem.waveform_samples[i+1]
    //         y1 := ypos + (wave_max_height / 2.0 - peak * (wave_max_height/2.0))
    //         next_y2 := ypos + (wave_max_height / 2.0 - next_peak * (wave_max_height/2.0))

    //         sdl3.SetRenderDrawColor(gmem.sdl_renderer, 100,255,100,255)
    //         sdl3.RenderLine(gmem.sdl_renderer, xpos, y1, next_xpos, next_y2)
    //     }

    //     ypos += wave_max_height + 10.0
    // }





    before_render_update_time := sdl3.GetTicks()
    frame_time_before_render_update := before_render_update_time- update_time_start
    {
        render_text_tprintf(gmem.sdl_renderer, f32(screen_width - 400), 0, 16.0, 255, 255,255,255, gmem.fonts[1], "frame time: %d ms", frame_time_before_render_update)
    }

    frame_time_after_render_update := sdl3.GetTicks()
    time_spent_rendering := frame_time_after_render_update - before_render_update_time
    // fmt.printfln("time spent rendering: %v",time_spent_rendering)

    sdl3.RenderPresent(gmem.sdl_renderer)
    free_all(context.temp_allocator)
    update_time_end := sdl3.GetTicks()

    frame_time := update_time_end - update_time_start


    max_frame_time := u32(math.floor(f32(1000.0/60.0)))
    delay_time := max_frame_time - u32(frame_time)
    delay_time = min(max_frame_time, delay_time)

    if delay_time > max_frame_time {
        fmt.printfln("wrong!")
    }

    sdl3.Delay(delay_time)
}