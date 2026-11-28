package migrations

import (
	"embed"
	"errors"
	"fmt"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/postgres"
	"github.com/golang-migrate/migrate/v4/source/iofs"
)

//go:embed *.up.sql
var files embed.FS

// Apply uses a separate operator command. The API never migrates on startup.
func Apply(dsn string) error {
	source, err := iofs.New(files, ".")
	if err != nil {
		return err
	}
	runner, err := migrate.NewWithSourceInstance("iofs", source, dsn)
	if err != nil {
		return errors.New("migration database unavailable or invalid")
	}
	defer runner.Close()
	if err := runner.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return fmt.Errorf("SQL migration failed: %w", err)
	}
	return nil
}
