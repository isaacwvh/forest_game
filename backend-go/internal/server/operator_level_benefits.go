package server

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

func activateLevelBenefits(ctx context.Context, tx pgx.Tx, boundary time.Time) (map[string]any, error) {
	const version = "level-benefits-v1"
	var exists bool
	if err := tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM level_benefits_policy WHERE version=$1)", version).Scan(&exists); err != nil {
		return nil, err
	}
	if exists {
		return map[string]any{"version": version, "alreadyActive": true}, nil
	}
	type account struct {
		owner   string
		garden  *string
		level   int64
		visitor *visitorRuntime
	}
	rows, err := tx.Query(ctx, `SELECT u.id::text,g.id::text,COALESCE(p.activity_steps,0) FROM users u
		LEFT JOIN gardens g ON g.owner_id=u.id LEFT JOIN player_progress p ON p.owner_id=u.id ORDER BY u.id`)
	if err != nil {
		return nil, err
	}
	owners, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (account, error) {
		var owner account
		var steps int64
		err := row.Scan(&owner.owner, &owner.garden, &steps)
		owner.level = levelForSteps(steps)
		return owner, err
	})
	if err != nil {
		return nil, err
	}
	app := Server{Environment: "local"}
	for i, owner := range owners {
		if owner.garden == nil {
			continue
		}
		visitor, err := app.settleVisitorState(ctx, tx, *owner.garden, owner.owner, boundary, false)
		if err != nil {
			return nil, err
		}
		if visitor.at.After(boundary) {
			return nil, visitorContextUnavailable
		}
		owners[i].visitor = visitor
	}
	if _, err := tx.Exec(ctx, "INSERT INTO level_benefits_policy(version,effective_at) VALUES($1,$2)", version, boundary); err != nil {
		return nil, err
	}
	for _, owner := range owners {
		if _, err := tx.Exec(ctx, `INSERT INTO account_level_state(owner_id,reached_level,presented_level)
			VALUES($1,$2,$2)`, owner.owner, owner.level); err != nil {
			return nil, err
		}
		if owner.visitor == nil {
			continue
		}
		config, err := readGardenStrategy(ctx, tx, owner.owner, boundary)
		if err != nil {
			return nil, err
		}
		garden := gardenRecord{id: *owner.garden, owner: owner.owner}
		copies, err := loadGardenCopies(ctx, tx, garden, gardenRequest{})
		if err != nil {
			return nil, err
		}
		view, err := app.evaluateGarden(ctx, tx, config, copies.facts(copies.initial))
		if err != nil {
			return nil, err
		}
		if err := app.replaceGardenContext(ctx, tx, owner.visitor, config, view); err != nil {
			return nil, err
		}
	}
	return map[string]any{"version": version, "accounts": len(owners), "alreadyActive": false}, nil
}
