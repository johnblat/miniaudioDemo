# Odin + SDL3 + miniaudio demo

## What's this repo?

A personal test bed for audio and music related applications using miniaudio.

This repo demonstrates the following things:
- Playback toggling
- Loop toggling
- Progress bar visualization
- Volume control and visualization
- Waveform visualization
- Beat and Meaure/Bar calculation
- "Manual" font rendering using stb_truetype
- Using stb_image to load an image into an SDL_Texture
- Animated Sprites using a Sprite Atlas
- Using the file dialogue popup to select a file with filters
- Hot reloading
  
Please feel free to use this in any way. If you find something particularly useful, a credit would be appreciated but not necesarry.

This was only tested on Windows.

## What's next to do?
- Make sure waveform updates when a new song is loaded
- Allow user to make new bpm for a new song that's loaded
- Save BPM -> file mapping so that the app remembers the bpm of different songs
- Allow user to insert silence at the beginning of the track for beat timing alignment
- Allow user to specify bpm changes
- Allow user to specify time signature for metronome and time signature changes
- Fix access violation bug when closing app after its been hot reloaded at least once
