package server

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/jackc/pgx/v5"
)

type visitorContextEntry struct {
	config  *visitorContext
	sources json.RawMessage
}

// Context snapshots and their pinned rules are immutable. Cache only by the
// context ID read from database state, and bound the number of retained IDs.
type visitorContextCache struct {
	mu     sync.Mutex
	values map[string]visitorContextEntry
	keys   [256]string
	next   int
}

func (c *visitorContextCache) get(id string) visitorContextEntry {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.values[id]
}

func (c *visitorContextCache) remember(id string, update visitorContextEntry) visitorContextEntry {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, known := c.values[id]
	if !known {
		if c.values == nil {
			c.values = make(map[string]visitorContextEntry, len(c.keys))
		}
		delete(c.values, c.keys[c.next])
		c.keys[c.next] = id
		c.next = (c.next + 1) % len(c.keys)
	}
	if entry.config == nil {
		entry.config = update.config
	}
	if entry.sources == nil {
		entry.sources = update.sources
	}
	c.values[id] = entry
	return entry
}

func (s *Server) cachedVisitorContext(ctx context.Context, tx pgx.Tx, id string) (visitorContext, error) {
	if saved := s.visitorContexts.get(id).config; saved != nil {
		return *saved, nil
	}
	value, err := readVisitorContext(ctx, tx, id)
	if err != nil {
		return value, err
	}
	return *s.visitorContexts.remember(id, visitorContextEntry{config: &value}).config, nil
}

func (s *Server) contextSources(ctx context.Context, tx pgx.Tx, id string) (json.RawMessage, error) {
	if value := s.visitorContexts.get(id).sources; value != nil {
		return value, nil
	}
	var value json.RawMessage
	if err := tx.QueryRow(ctx, `SELECT COALESCE(snapshot->'sources','[]') FROM visitor_contexts WHERE id=$1`, id).Scan(&value); err != nil {
		return nil, err
	}
	return s.visitorContexts.remember(id, visitorContextEntry{sources: value}).sources, nil
}
