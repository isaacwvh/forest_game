package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"forestivity/backend/internal/server"
	"github.com/jackc/pgx/v5/pgxpool"
)

func isOperatorCommand(command string) bool {
	switch command {
	case "storage-report", "history-backlog", "maintain-history", "compact-requests",
		"backfill-progression", "backfill-milestones", "schedule-milestone-event", "retire-offer", "activate-level-benefits",
		"publish-pack", "publish-visitor-rules":
		return true
	}
	return false
}

func runOperatorCommand(command string, arguments []string, dsn, environment string) error {
	options := server.OperatorOptions{Command: command}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	var input string
	var effective string
	switch command {
	case "storage-report":
		flags.BoolVar(&options.Exact, "exact", false, "count every row instead of reading PostgreSQL estimates")
	case "history-backlog":
	case "activate-level-benefits":
		flags.BoolVar(&options.Apply, "apply", false, "settle visitor history and activate level benefits")
	case "schedule-milestone-event":
		flags.StringVar(&input, "file", "", "milestone event definition (JSON)")
		flags.BoolVar(&options.Apply, "apply", false, "publish the event")
	case "publish-pack":
		flags.StringVar(&input, "file", "", "pack and offer definition (JSON)")
		flags.BoolVar(&options.Apply, "apply", false, "publish the pack and offer")
	case "publish-visitor-rules":
		flags.StringVar(&input, "file", "", "visitor rules definition (JSON)")
		flags.StringVar(&options.Rules.Version, "version", "", "new rule version")
		flags.StringVar(&effective, "effective-at", "", "future RFC3339 timestamp with offset")
		flags.BoolVar(&options.Rules.Fixture, "fixture", false, "mark this as a local fixture")
		flags.BoolVar(&options.Apply, "apply", false, "publish the rule version")
	case "retire-offer":
		flags.StringVar(&options.OfferID, "offer", "", "offer identifier")
		flags.IntVar(&options.OfferVersion, "version", 0, "offer version")
		flags.BoolVar(&options.Apply, "apply", false, "retire the offer")
	default:
		flags.BoolVar(&options.Apply, "apply", false, "commit the pass instead of rolling it back")
		flags.IntVar(&options.Limit, "limit", 500, "maximum batch size, 1 to 5000")
	}
	if command == "maintain-history" {
		flags.BoolVar(&options.Responses, "responses", false, "maintain request receipts")
		flags.BoolVar(&options.Visitors, "visitors", false, "maintain visitor history")
		flags.BoolVar(&options.Growth, "growth", false, "maintain growth history")
	}
	if err := flags.Parse(arguments); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	switch command {
	case "schedule-milestone-event":
		if err := readOperatorJSON(input, &options.Event); err != nil {
			return err
		}
	case "publish-pack":
		options.Pack.Currency = "tokens"
		if err := readOperatorJSON(input, &options.Pack); err != nil {
			return err
		}
	case "publish-visitor-rules":
		var err error
		options.Rules.Effective, err = time.Parse(time.RFC3339, effective)
		if err != nil {
			return errors.New("specify --effective-at as an RFC3339 timestamp with offset")
		}
		if err := readOperatorJSON(input, &options.Rules.Definition); err != nil {
			return err
		}
	}
	config, err := localReleaseConfig(dsn, environment)
	if err != nil {
		return err
	}
	config.MaxConns = 1
	config.ConnConfig.ConnectTimeout = 5 * time.Second
	config.ConnConfig.RuntimeParams["lock_timeout"] = "3000"
	config.ConnConfig.RuntimeParams["statement_timeout"] = "45000"
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return errors.New("operator database unavailable")
	}
	defer pool.Close()
	report, err := server.RunLocalOperator(ctx, pool, options)
	if err != nil {
		return err
	}
	output := json.NewEncoder(os.Stdout)
	output.SetIndent("", "  ")
	return output.Encode(report)
}

func readOperatorJSON(path string, target any) error {
	if path == "" {
		return errors.New("--file is required")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	const maxBytes = 8 * 1024 * 1024
	if info, err := file.Stat(); err != nil {
		return err
	} else if !info.Mode().IsRegular() || info.Size() > maxBytes {
		return errors.New("operator input must be a regular file of at most 8 MiB")
	}
	decoder := json.NewDecoder(io.LimitReader(file, maxBytes+1))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(new(json.RawMessage)); err != io.EOF {
		return errors.New("expected one JSON object")
	}
	return nil
}
