use buzz_voice_pkg::preparation::{shape_tts_model_unit, TTS_SAMPLE_RATE};

const SENTENCE_LEAD_IN_SAMPLES: usize = TTS_SAMPLE_RATE * 20 / 1_000;

/// The onset cushion covers 20 ms at the production sample rate.
#[test]
fn sentence_lead_in_is_sane() {
    assert_eq!(SENTENCE_LEAD_IN_SAMPLES, 480, "20 ms × 24 kHz");
}

/// Model-token splits remain contiguous: only the playback chunk as a whole
/// receives its onset cushion and trailing sentence gap.
#[test]
fn token_split_units_do_not_add_sentence_boundary_padding() {
    let silence_buf_len = 2400;
    let first_unit = shape_tts_model_unit(vec![0.5; 100], true, false);
    let last_unit = shape_tts_model_unit(vec![0.25; 100], false, true);

    assert_eq!(first_unit.len(), SENTENCE_LEAD_IN_SAMPLES + 100);
    assert_eq!(first_unit.last(), Some(&0.5));
    assert_eq!(last_unit.first(), Some(&0.25));
    assert_eq!(first_unit.len() + last_unit.len(), 200 + silence_buf_len);
}
