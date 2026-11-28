package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
	_ "time/tzdata"

	"forestivity/backend/internal/server"
	"forestivity/backend/migrations"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	if err := run(); err != nil {
		slog.Error("forest exited", "reason", err.Error())
		os.Exit(1)
	}
}

func run() error {
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}
	dsn := os.Getenv("FOREST_DATABASE_URL")
	environment := os.Getenv("FOREST_ENVIRONMENT")
	if environment == "" {
		environment = "local"
	}
	if command == "migrate" {
		return migrations.Apply(dsn)
	}
	if isReleaseCommand(command) {
		return runReleaseCommand(command, os.Args[2:], dsn, environment)
	}
	if command == "healthcheck" {
		client := http.Client{Timeout: 2 * time.Second}
		res, err := client.Get("http://127.0.0.1:" + port() + "/health/ready")
		if err != nil {
			return errors.New("health endpoint unavailable")
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return errors.New("service is not ready")
		}
		return nil
	}
	if command != "serve" && command != "worker" && command != "dev-token" {
		return errors.New("expected serve, worker, migrate, dev-token, healthcheck or a local release command")
	}

	var verifier *server.Verifier
	var err error
	switch os.Getenv("FOREST_AUTH_MODE") {
	case "development":
		verifier, err = server.DevelopmentVerifier(environment, os.Getenv("FOREST_DEV_AUTH_SECRET"))
	case "", "jwks":
		algorithm := os.Getenv("FOREST_AUTH_ALGORITHM")
		if algorithm == "" {
			algorithm = "RS256"
		}
		verifier, err = server.RemoteVerifier(algorithm, os.Getenv("FOREST_AUTH_ISSUER"), os.Getenv("FOREST_AUTH_AUDIENCE"), os.Getenv("FOREST_AUTH_JWKS_URL"))
	default:
		return errors.New("unknown authentication mode")
	}
	if err != nil && command != "worker" {
		return err
	}
	if command == "dev-token" {
		if len(os.Args) != 3 {
			return errors.New("expected dev-token SUBJECT")
		}
		token, err := verifier.IssueDevelopmentToken(os.Args[2])
		if err != nil {
			return err
		}
		fmt.Println(token)
		return nil
	}
	if dsn == "" {
		return errors.New("FOREST_DATABASE_URL is required")
	}
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return errors.New("invalid database configuration")
	}
	config.MaxConns = 2
	if command == "worker" {
		config.MaxConns = 1
	}
	config.ConnConfig.ConnectTimeout = 5 * time.Second
	config.ConnConfig.RuntimeParams["statement_timeout"] = "15000"
	config.ConnConfig.RuntimeParams["lock_timeout"] = "3000"

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return errors.New("database pool unavailable")
	}
	defer pool.Close()
	app := &server.Server{Pool: pool, Auth: verifier, Environment: environment}
	handler := app.Handler()
	if command == "worker" {
		app.WorkerConfig, err = workerConfig(environment)
		if err != nil {
			return err
		}
		handler = app.WorkerHandler()
	}
	httpServer := &http.Server{
		Addr: ":" + port(), Handler: handler, ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 15 * time.Second, WriteTimeout: 50 * time.Second, IdleTimeout: 30 * time.Second,
	}
	done := make(chan error, 1)
	go func() { done <- httpServer.ListenAndServe() }()
	slog.Info("forest listening", "component", command, "port", port())
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("HTTP listener: %w", err)
		}
	case <-ctx.Done():
		terminating, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(terminating); err != nil {
			_ = httpServer.Close()
			return err
		}
	}
	return nil
}

func port() string {
	value := os.Getenv("PORT")
	if parsed, err := strconv.Atoi(value); err != nil || parsed < 1 || parsed > 65535 {
		return "8000"
	}
	return value
}

func workerConfig(environment string) (*server.WorkerConfig, error) {
	local := environment == "local" || environment == "test"
	config := &server.WorkerConfig{Budget: 40 * time.Second, BatchLimit: 500, Responses: local, Visitors: local, Growth: local}
	if raw := os.Getenv("FOREST_WORKER_BUDGET_SECONDS"); raw != "" {
		seconds, err := strconv.ParseFloat(raw, 64)
		if err != nil || !(seconds >= 1 && seconds <= 45) {
			return nil, errors.New("FOREST_WORKER_BUDGET_SECONDS must be between 1 and 45")
		}
		config.Budget = time.Duration(seconds * float64(time.Second))
	}
	if raw := os.Getenv("FOREST_MAINTENANCE_BATCH_LIMIT"); raw != "" {
		limit, err := strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 5000 {
			return nil, errors.New("FOREST_MAINTENANCE_BATCH_LIMIT must be between 1 and 5000")
		}
		config.BatchLimit = limit
	}
	for _, option := range []struct {
		name   string
		target *bool
	}{
		{"FOREST_MAINTENANCE_RESPONSES_ENABLED", &config.Responses},
		{"FOREST_MAINTENANCE_VISITORS_ENABLED", &config.Visitors},
		{"FOREST_MAINTENANCE_GROWTH_ENABLED", &config.Growth},
		{"FOREST_OPERATION_METRICS_ENABLED", &config.Metrics},
	} {
		if raw := os.Getenv(option.name); raw != "" {
			value, err := strconv.ParseBool(raw)
			if err != nil {
				return nil, fmt.Errorf("%s must be a boolean", option.name)
			}
			*option.target = value
		}
	}
	return config, nil
}
