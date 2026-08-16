import 'rick_roll_tune.dart';

/// Non-web stub for the Konami hook: there is no audio dependency in this app
/// (the only sound code is dictation *recording*), and adding an audio plugin
/// plus its per-platform boilerplate to make an easter egg audible on mobile
/// is not a trade worth making — the code needs arrow keys anyway, so the
/// mobile builds can never reach it.
///
/// VM widget tests resolve to this file too, which is what keeps them silent
/// and synchronous. The overlay is written to look identical either way.
///
/// See rick_roll_audio_web.dart for the real implementation and
/// rick_roll_tune.dart for the contract.
RickRollPlayback playRickRollHook() => const SilentRickRollPlayback();
