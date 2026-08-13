-- Local sources ------------------------------------------------------------

-- name: CreateLocalSource :one
INSERT INTO local_sources (name, bio, photo_url, location, expertise, credibility, consent_ref)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetLocalSource :one
SELECT * FROM local_sources WHERE id = $1;

-- name: ListLocalSources :many
SELECT * FROM local_sources ORDER BY name ASC;

-- Source material (ingestion provenance) ------------------------------------

-- name: CreateSourceMaterial :one
INSERT INTO local_source_material (source_id, kind, raw_text)
VALUES ($1, $2, $3)
RETURNING *;

-- Recommendations -----------------------------------------------------------

-- name: CreateLocalRecommendation :one
INSERT INTO local_recommendations
    (source_id, city, neighborhood, name, place_id, address, latitude, longitude,
     category, tip, quote, tags, status, place_verified)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
RETURNING *;

-- name: GetLocalRecommendation :one
SELECT * FROM local_recommendations WHERE id = $1;

-- name: UpdateLocalRecommendation :one
-- Partial update (COALESCE sqlc.narg idiom, see query/trips.sql UpdateTrip).
UPDATE local_recommendations
SET city           = COALESCE(sqlc.narg('city'), city),
    neighborhood   = COALESCE(sqlc.narg('neighborhood'), neighborhood),
    name           = COALESCE(sqlc.narg('name'), name),
    place_id       = COALESCE(sqlc.narg('place_id'), place_id),
    address        = COALESCE(sqlc.narg('address'), address),
    latitude       = COALESCE(sqlc.narg('latitude'), latitude),
    longitude      = COALESCE(sqlc.narg('longitude'), longitude),
    category       = COALESCE(sqlc.narg('category'), category),
    tip            = COALESCE(sqlc.narg('tip'), tip),
    quote          = COALESCE(sqlc.narg('quote'), quote),
    place_verified = COALESCE(sqlc.narg('place_verified'), place_verified)
WHERE id = sqlc.arg('id')
RETURNING *;

-- name: SetLocalRecommendationStatus :one
UPDATE local_recommendations SET status = $2 WHERE id = $1 RETURNING *;

-- name: ListRecommendationsByStatus :many
-- Admin curation queue, newest first, with the local's attribution fields.
SELECT r.*, s.name AS source_name, s.photo_url AS source_photo_url,
       s.credibility AS source_credibility
FROM local_recommendations r
JOIN local_sources s ON s.id = r.source_id
WHERE r.status = $1
ORDER BY r.created_at DESC;

-- name: ListPublishedRecommendationsByCity :many
-- Hot read path (agent + browse). Attribution joined in.
SELECT r.*, s.name AS source_name, s.bio AS source_bio, s.photo_url AS source_photo_url,
       s.expertise AS source_expertise, s.credibility AS source_credibility
FROM local_recommendations r
JOIN local_sources s ON s.id = r.source_id
WHERE r.city ILIKE $1 AND r.status = 'published'
ORDER BY r.created_at DESC;

-- name: CountRecommendationsByCityStatus :many
-- Coverage: how many published/draft pins exist per city.
SELECT city, status, count(*) AS n
FROM local_recommendations
GROUP BY city, status
ORDER BY city ASC, status ASC;

-- Guides --------------------------------------------------------------------

-- name: CreateLocalGuide :one
INSERT INTO local_guides (source_id, title, city, neighborhood, body, hero_image_url, status)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: GetLocalGuide :one
SELECT g.*, s.name AS source_name, s.bio AS source_bio, s.photo_url AS source_photo_url,
       s.expertise AS source_expertise, s.credibility AS source_credibility
FROM local_guides g
JOIN local_sources s ON s.id = g.source_id
WHERE g.id = $1;

-- name: ListPublishedGuidesByCity :many
SELECT g.*, s.name AS source_name, s.photo_url AS source_photo_url
FROM local_guides g
JOIN local_sources s ON s.id = g.source_id
WHERE g.city ILIKE $1 AND g.status = 'published'
ORDER BY g.created_at DESC;

-- name: ListPublishedGuides :many
-- Cross-city discover list (home screen row): newest published guides first,
-- with the same source attribution join as ListPublishedGuidesByCity.
SELECT g.*, s.name AS source_name, s.photo_url AS source_photo_url
FROM local_guides g
JOIN local_sources s ON s.id = g.source_id
WHERE g.status = 'published'
ORDER BY g.created_at DESC
LIMIT $1;

-- name: LinkGuideRecommendation :exec
INSERT INTO local_guide_recommendations (guide_id, recommendation_id, position)
VALUES ($1, $2, $3)
ON CONFLICT (guide_id, recommendation_id) DO UPDATE SET position = EXCLUDED.position;

-- name: ListRecommendationsByGuide :many
-- Published pins belonging to a guide, in narrative order, with attribution.
SELECT r.*, s.name AS source_name, s.photo_url AS source_photo_url,
       s.credibility AS source_credibility, gr.position AS guide_position
FROM local_guide_recommendations gr
JOIN local_recommendations r ON r.id = gr.recommendation_id
JOIN local_sources s ON s.id = r.source_id
WHERE gr.guide_id = $1 AND r.status = 'published'
ORDER BY gr.position ASC;
