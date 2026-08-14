-- name: GetPreferences :one
SELECT * FROM traveler_preferences WHERE user_id = $1;

-- name: UpsertPreferences :one
INSERT INTO traveler_preferences (user_id, budget, pace, interests, home_airport, profile_notes, work_style, fitness_routine, outdoor_intensity, companions)
VALUES (
    sqlc.arg('user_id'),
    sqlc.narg('budget'),
    sqlc.narg('pace'),
    COALESCE(sqlc.narg('interests'), '{}'::text[]),
    sqlc.narg('home_airport'),
    sqlc.narg('profile_notes'),
    sqlc.narg('work_style'),
    sqlc.narg('fitness_routine'),
    sqlc.narg('outdoor_intensity'),
    sqlc.narg('companions')
)
ON CONFLICT (user_id) DO UPDATE SET
    budget            = COALESCE(sqlc.narg('budget'), traveler_preferences.budget),
    pace              = COALESCE(sqlc.narg('pace'), traveler_preferences.pace),
    interests         = COALESCE(sqlc.narg('interests'), traveler_preferences.interests),
    home_airport      = COALESCE(sqlc.narg('home_airport'), traveler_preferences.home_airport),
    profile_notes     = COALESCE(sqlc.narg('profile_notes'), traveler_preferences.profile_notes),
    work_style        = COALESCE(sqlc.narg('work_style'), traveler_preferences.work_style),
    fitness_routine   = COALESCE(sqlc.narg('fitness_routine'), traveler_preferences.fitness_routine),
    outdoor_intensity = COALESCE(sqlc.narg('outdoor_intensity'), traveler_preferences.outdoor_intensity),
    companions        = COALESCE(sqlc.narg('companions'), traveler_preferences.companions)
RETURNING *;
