/// Mirrors the underlying audio engine's processing state, independent of
/// any specific engine so the rest of the app never imports `just_audio`.
enum PlaybackProcessingState { idle, loading, buffering, ready, completed }
