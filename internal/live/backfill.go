package live

import (
	"context"
	"errors"
	"fmt"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

var errBackfillDeferred = errors.New("history backfill deferred to keep the phone's workload bounded")

func needsHistory(store *archive.Store, id string, since time.Time) (bool, error) {
	coverage, err := store.Meta("history_coverage:" + id)
	if err != nil {
		return false, err
	}
	if parsed, err := time.Parse("2006-01-02", coverage); err == nil {
		return parsed.After(since), nil
	}
	floor, err := store.Meta("retention_floor")
	if err != nil {
		return false, err
	}
	if date, err := time.Parse("2006-01-02", floor); err == nil && since.Before(date) {
		return true, nil
	}
	p, err := store.Progress(id)
	if err != nil {
		return false, err
	}
	complete := p.State == "boundary_reached" || p.State == "source_exhausted"
	return !complete || p.Since.After(since), nil
}

func backfillHistory(ctx context.Context, store *archive.Store, source history.Source, id string, opts Options) error {
	needed, err := needsHistory(store, id, opts.Since)
	if err != nil || !needed {
		return err
	}
	p, err := store.Progress(id)
	if err != nil {
		return err
	}
	resume := p.Since.Equal(opts.Since) && p.State != "boundary_reached" && p.State != "source_exhausted"
	// Backfill yields its conversation lock after one page so a new message
	// does not wait for a multi-year import of that same conversation.
	p, err = history.Import(ctx, store, source, id, history.Options{Since: opts.Since, MaxPages: 1, Resume: resume})
	if err != nil {
		return err
	}
	if p.State != "boundary_reached" && p.State != "source_exhausted" {
		return fmt.Errorf("history backfill remains incomplete")
	}
	return store.SetMeta("history_coverage:"+id, opts.Since.Format("2006-01-02"))
}
