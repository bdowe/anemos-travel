-- +goose Up
ALTER TABLE traveler_preferences ADD COLUMN fitness_routine text;   -- gym | running | both | none
ALTER TABLE traveler_preferences ADD COLUMN outdoor_intensity text; -- easy | moderate | challenging
ALTER TABLE traveler_preferences ADD COLUMN companions text;        -- solo | partner | friends | family_with_kids | varies

-- Companions was already collected by the signup quiz, but with no column to
-- land in it was folded into profile_notes as a "- Travels with: X" bullet
-- (buildOnboardingProfileNotes). The distiller rewrites notes wholesale on
-- every trip, so the fact was one rewording away from vanishing. Move it to
-- the column so it has exactly one home (docs/zen.md: explicit over implicit).
--
-- The bullet is a hardcoded English literal, never localized, so an exact
-- whole-line match is safe. Anything else — a distiller rewording like
-- "- Travels with: my partner" — is deliberately NOT guessed at: it leaves
-- companions NULL and keeps its bullet below.
UPDATE traveler_preferences
SET companions = CASE
        WHEN profile_notes ~ '(^|\n)- Travels with: solo(\n|$)'             THEN 'solo'
        WHEN profile_notes ~ '(^|\n)- Travels with: partner(\n|$)'          THEN 'partner'
        WHEN profile_notes ~ '(^|\n)- Travels with: friends(\n|$)'          THEN 'friends'
        WHEN profile_notes ~ '(^|\n)- Travels with: family with kids(\n|$)' THEN 'family_with_kids'
        WHEN profile_notes ~ '(^|\n)- Travels with: it varies(\n|$)'        THEN 'varies'
    END
WHERE companions IS NULL AND profile_notes LIKE '%- Travels with: %';

-- Strip ONLY the five exact bullets, so the reworded case above keeps its line
-- and neither branch loses information. A note that was nothing but the bullet
-- becomes NULL rather than an empty string.
UPDATE traveler_preferences
SET profile_notes = NULLIF(
        btrim(
            regexp_replace(
                profile_notes,
                '(^|\n)- Travels with: (solo|partner|friends|family with kids|it varies)(?=\n|$)',
                '', 'g'),
            E' \n'),
        '')
WHERE companions IS NOT NULL AND profile_notes LIKE '%- Travels with: %';

-- +goose Down
-- Note: the profile_notes edit above is NOT reversed — the stripped bullets are
-- gone. Down is dev-only here; a rollback leaves those travelers with neither
-- the column nor the note. Acceptable: the column is the new source of truth.
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS companions;
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS outdoor_intensity;
ALTER TABLE traveler_preferences DROP COLUMN IF EXISTS fitness_routine;
