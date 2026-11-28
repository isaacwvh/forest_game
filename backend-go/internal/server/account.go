package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type Profile struct {
	ID          string    `json:"userId"`
	Username    string    `json:"username"`
	DisplayName string    `json:"displayName"`
	Timezone    string    `json:"gameTimezone"`
	Created     time.Time `json:"createdAt"`
	status      string
}

type Account struct {
	Profile   Profile `json:"profile"`
	GardenID  string  `json:"gardenId"`
	StarterID string  `json:"starterPlantId"`
}

const profileColumns = "id::text, username, display_name, game_timezone, created_at, status"

var (
	accountRequired      = &apiError{403, "account_required", "Complete account setup first"}
	accountDisabled      = &apiError{403, "account_disabled", "Account is disabled"}
	usernameTaken        = &apiError{409, "username_unavailable", "Username is unavailable"}
	catalogueUnavailable = &apiError{503, "catalogue_unavailable", "Game catalogue has not been configured"}
	usernamePattern      = regexp.MustCompile("^[A-Za-z0-9_]{3,32}$")
)

func scanProfile(row pgx.Row) (Profile, error) {
	var p Profile
	err := row.Scan(&p.ID, &p.Username, &p.DisplayName, &p.Timezone, &p.Created, &p.status)
	p.Created = p.Created.UTC()
	return p, err
}

func lookupProfile(ctx context.Context, tx pgx.Tx, identity Identity, lock bool) (Profile, error) {
	query := "SELECT " + profileColumns + " FROM users WHERE auth_issuer=$1 AND auth_subject=$2"
	if lock {
		query += " FOR UPDATE"
	}
	p, err := scanProfile(tx.QueryRow(ctx, query, identity.Issuer, identity.Subject))
	if errors.Is(err, pgx.ErrNoRows) {
		return p, accountRequired
	}
	if err == nil && p.status != "active" {
		return p, accountDisabled
	}
	return p, err
}

func (s *Server) profile(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	return lookupProfile(r.Context(), tx, id, false)
}

func requestID(body map[string]json.RawMessage) (uuid.UUID, error) {
	value, err := stringField(body, "requestId")
	if err != nil {
		return uuid.Nil, err
	}
	id, err := uuid.Parse(value)
	if err != nil {
		return uuid.Nil, invalid
	}
	return id, nil
}

func displayName(value string) (string, error) {
	clean := strings.TrimSpace(value)
	if utf8.RuneCountInString(value) > 64 || clean == "" || strings.ContainsFunc(clean, func(r rune) bool {
		return r < 32 || r == 127
	}) {
		return "", invalid
	}
	return clean, nil
}

func (s *Server) register(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	bootstrap := r.URL.Path == "/v1/accounts/bootstrap"
	fields := []string{"requestId", "gameTimezone"}
	if !bootstrap {
		fields = append(fields, "username", "displayName")
	}
	body, err := readBody(r, fields...)
	if err != nil {
		return nil, err
	}
	key, err := requestID(body)
	if err != nil {
		return nil, err
	}
	zone, err := stringField(body, "gameTimezone")
	if err != nil || zone == "Local" || zone == "" || len(zone) > 64 {
		return nil, invalid
	}
	if _, err := time.LoadLocation(zone); err != nil {
		return nil, invalid
	}

	operation := "bootstrap_account"
	username, name := "", "New Gardener"
	payload := map[string]any{"gameTimezone": zone}
	if !bootstrap {
		operation = "register_account"
		rawUsername, err := stringField(body, "username")
		if err != nil || !usernamePattern.MatchString(rawUsername) {
			return nil, invalid
		}
		username = strings.ToLower(rawUsername)
		rawName, err := stringField(body, "displayName")
		if err != nil {
			return nil, err
		}
		name, err = displayName(rawName)
		if err != nil {
			return nil, err
		}
		payload["username"], payload["displayName"] = username, name
	}
	digest, err := requestDigest(operation, payload)
	if err != nil {
		return nil, err
	}
	lockKey, err := canonicalJSON([]string{id.Issuer, id.Subject})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock_shared(hashtextextended('forest-content-release', 0))"); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", string(lockKey)); err != nil {
		return nil, err
	}
	p, err := lookupProfile(ctx, tx, id, true)
	switch {
	case err == nil:
		if saved, err := replay(ctx, tx, p.ID, key, operation, digest, r.Header.Get("X-Forest-Recovery") == "1"); err != nil || saved != nil {
			return saved, err
		}
	case errors.Is(err, accountRequired):
		catalog, err := s.catalogueState(ctx, tx)
		if err != nil {
			return nil, err
		}
		if catalog.Version == "woodland-v1" && r.Header.Get("X-Forest-Woodland") != "1" {
			return nil, &apiError{426, "woodland_client_update_required", "Update the app to begin your garden"}
		}
		for range 4 {
			if bootstrap {
				username = "gardener_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:20]
			}
			p, err = scanProfile(tx.QueryRow(ctx, `INSERT INTO users (id, auth_issuer, auth_subject, username, display_name, game_timezone)
				VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (lower(username)) DO NOTHING RETURNING `+profileColumns,
				uuid.New(), id.Issuer, id.Subject, username, name, zone))
			if !errors.Is(err, pgx.ErrNoRows) || !bootstrap {
				break
			}
		}
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, usernameTaken
		}
		if err != nil {
			return nil, err
		}
		if err := initializeAccount(ctx, tx, p.ID); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	result := Account{Profile: p}
	err = tx.QueryRow(ctx, `SELECT g.id::text, p.id::text
		FROM gardens g JOIN owned_plants p ON p.owner_id=g.owner_id
		WHERE g.owner_id=$1 AND p.acquisition_source='starter' AND p.acquisition_reference='initial-starter-v1'`, p.ID).
		Scan(&result.GardenID, &result.StarterID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{503, "account_setup_incomplete", "Your garden needs recovery"}
	}
	if err != nil {
		return nil, err
	}
	return result, saveSmallRecoveryReceipt(r, tx, p.ID, key, operation, digest, result)
}

func initializeAccount(ctx context.Context, tx pgx.Tx, owner string) error {
	result, err := tx.Exec(ctx, `
		INSERT INTO owned_plants (
			id, owner_id, species_id, variant_id, growth_profile_id, growth_profile_version,
			behaviour_profile_id, behaviour_profile_version, attraction_profile_id, attraction_profile_version,
			acquisition_source, acquisition_reference, clearance_radius)
		SELECT $1, $2, p.id, v.variant_id,
			COALESCE(p.properties #>> '{starterGrowthProfile,id}', v.growth_profile_id, p.growth_profile_id),
			COALESCE((p.properties #>> '{starterGrowthProfile,version}')::int, v.growth_profile_version, p.growth_profile_version),
			COALESCE(v.behaviour_profile_id, p.behaviour_profile_id),
			COALESCE(v.behaviour_profile_version, p.behaviour_profile_version),
			COALESCE(v.attraction_profile_id, p.attraction_profile_id),
			COALESCE(v.attraction_profile_version, p.attraction_profile_version),
			'starter', 'initial-starter-v1', p.clearance_radius
		FROM game_catalogue c
		JOIN plant_species p ON p.id=c.starter_species_id AND p.enabled
		JOIN plant_variants v ON v.species_id=p.id AND v.variant_id=c.starter_variant_id AND v.enabled
		WHERE c.id=1 AND (SELECT count(*) FROM plant_stages s WHERE (s.species_id,s.variant_id)=(p.id,v.variant_id))=4`, uuid.New(), owner)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return &apiError{503, "plant_unavailable", "Award catalogue entry is unavailable"}
	}
	var batch pgx.Batch
	batch.Queue("INSERT INTO gardens (id, owner_id, width, depth) SELECT $1,$2,board_width,board_depth FROM game_catalogue WHERE id=1", uuid.New(), owner)
	batch.Queue("INSERT INTO player_progress (owner_id, activity_steps, first_maturity_count) VALUES ($1,0,0)", owner)
	batch.Queue("INSERT INTO visitor_wallets (owner_id, tokens, hosted_active, hosted_offline, progression_initialized) VALUES ($1,0,0,0,true)", owner)
	batch.Queue("INSERT INTO account_level_state (owner_id, reached_level, presented_level) SELECT $1,1,1 FROM level_benefits_policy WHERE version='level-benefits-v1'", owner)
	batch.Queue("INSERT INTO catalog_discovery_state (owner_id, version) VALUES ($1,1)", owner)
	batch.Queue("INSERT INTO catalog_stage_discoveries (owner_id, species_id, variant_id, stage) SELECT $1,starter_species_id,starter_variant_id,'sprout' FROM game_catalogue WHERE id=1", owner)
	return tx.SendBatch(ctx, &batch).Close()
}

func (s *Server) updateProfile(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	body, err := readBody(r, "requestId", "username", "displayName")
	if err != nil || len(body) < 2 {
		return nil, invalid
	}
	key, err := requestID(body)
	if err != nil {
		return nil, err
	}
	var username, name *string
	if body["username"] != nil {
		value, err := stringField(body, "username")
		if err != nil || !usernamePattern.MatchString(value) {
			return nil, invalid
		}
		value = strings.ToLower(value)
		username = &value
	}
	if body["displayName"] != nil {
		value, err := stringField(body, "displayName")
		if err != nil {
			return nil, err
		}
		value, err = displayName(value)
		if err != nil {
			return nil, err
		}
		name = &value
	}
	const operation = "update_profile"
	digest, err := requestDigest(operation, map[string]any{"username": username, "displayName": name})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if saved, err := replay(ctx, tx, p.ID, key, operation, digest, r.Header.Get("X-Forest-Recovery") == "1"); err != nil || saved != nil {
		return saved, err
	}
	p, err = scanProfile(tx.QueryRow(ctx, `UPDATE users SET username=COALESCE($2,username),
		display_name=COALESCE($3,display_name), updated_at=clock_timestamp()
		WHERE id=$1 RETURNING `+profileColumns, p.ID, username, name))
	if err != nil {
		var dbError *pgconn.PgError
		if errors.As(err, &dbError) && dbError.ConstraintName == "uq_users_username_normalized" {
			return nil, usernameTaken
		}
		return nil, err
	}
	return p, saveSmallRecoveryReceipt(r, tx, p.ID, key, operation, digest, p)
}

func replay(ctx context.Context, tx pgx.Tx, owner string, request uuid.UUID, operation, digest string, recovery bool) (json.RawMessage, error) {
	var oldOperation, oldDigest string
	var result, completion json.RawMessage
	err := tx.QueryRow(ctx, `SELECT operation,payload_hash,response,completion->'outcome'
		FROM api_requests WHERE user_id=$1 AND request_id=$2`, owner, request).
		Scan(&oldOperation, &oldDigest, &result, &completion)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if oldOperation != operation || oldDigest != digest {
		return nil, &apiError{409, "idempotency_conflict", "Request ID was used for different input"}
	}
	if result != nil {
		return result, nil
	}
	if !recovery {
		return nil, &apiError{426, "recovery_client_update_required", "Update the app to recover this request"}
	}
	if completion == nil {
		return nil, &apiError{503, "recovery_unavailable", "The saved request needs recovery"}
	}
	return completion, nil
}

func saveReceipt(ctx context.Context, tx pgx.Tx, owner string, request uuid.UUID, operation, digest string, result any) error {
	_, err := tx.Exec(ctx, `INSERT INTO api_requests
		(user_id,request_id,operation,payload_hash,response)
		VALUES ($1,$2,$3,$4,$5::jsonb)`, owner, request, operation, digest, result)
	return err
}
