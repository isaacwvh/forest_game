package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"forestivity/backend/internal/server"
	"github.com/jackc/pgx/v5/pgxpool"
)

func isReleaseCommand(command string) bool {
	switch command {
	case "publish-release", "publish-woodland", "publish-item-catalogue", "activate-milestones", "publish-expedition", "prepare-shop", "preview-shop", "fund-release-test":
		return true
	default:
		return false
	}
}

func runReleaseCommand(command string, arguments []string, dsn, environment string) error {
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	options := server.ReleaseOptions{Command: command}
	if command != "preview-shop" {
		flags.BoolVar(&options.Apply, "apply", false, "commit changes instead of previewing")
	}
	var date string
	switch command {
	case "publish-expedition":
		flags.StringVar(&date, "month", "", "first day of the UTC month (YYYY-MM-DD)")
		flags.BoolVar(&options.StartNow, "start-now", false, "start the first expedition in the current UTC month")
	case "preview-shop":
		flags.StringVar(&date, "week", "", "Monday of the saved UTC week (YYYY-MM-DD)")
	case "fund-release-test":
		flags.StringVar(&options.Subject, "subject", "", "subject of the local development account to fund once")
	}
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if command == "publish-expedition" || command == "preview-shop" {
		day, err := time.Parse(time.DateOnly, date)
		if err != nil {
			return errors.New("specify the required date in YYYY-MM-DD format")
		}
		if command == "preview-shop" && day.Weekday() != time.Monday {
			return errors.New("Shop week must be a Monday UTC")
		}
		options.Month, options.Week = day, day
	}
	config, err := localReleaseConfig(dsn, environment)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return errors.New("release database unavailable")
	}
	defer pool.Close()
	report, err := server.RunLocalRelease(ctx, pool, options)
	if err != nil {
		return fmt.Errorf("%s: %w", command, err)
	}
	output := json.NewEncoder(os.Stdout)
	output.SetIndent("", "  ")
	return output.Encode(report)
}

func localReleaseConfig(dsn, environment string) (*pgxpool.Config, error) {
	if environment != "local" && environment != "test" {
		return nil, errors.New("release fixtures require a local or test environment")
	}
	if dsn == "" {
		return nil, errors.New("FOREST_DATABASE_URL is required")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, errors.New("invalid release database configuration")
	}
	if !localReleaseHost(config.ConnConfig.Host) {
		return nil, errors.New("release fixtures require a loopback or local Compose database")
	}
	for _, fallback := range config.ConnConfig.Fallbacks {
		if !localReleaseHost(fallback.Host) {
			return nil, errors.New("release fixtures require a loopback or local Compose database")
		}
	}
	return config, nil
}

func localReleaseHost(host string) bool {
	return host == "127.0.0.1" || host == "::1" || host == "db"
}
