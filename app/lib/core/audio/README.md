# core/audio

Phase 1: `AudioPlayerController`, the interface the rest of the app uses for
playback (play/pause/seek/skip, queue, shuffle, repeat), backed by a
`just_audio` + `audio_service` implementation.

Phase 1.5: mono/stereo and equalizer support via platform channels (Android:
`android.media.audiofx`); Windows/Linux support is not guaranteed.
