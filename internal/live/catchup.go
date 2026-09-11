package live

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

// CatchUp has its own durable watermark. Committing part of a failed catch-up
// must not move the boundary forward and strand messages in the missing gap.
func CatchUp(ctx context.Context, store *archive.Store, source history.Source, id string, since, changedAt time.Time, maxPages int) error {
	key := "live_checkpoint:" + id
	value, err := store.Meta(key)
	if err != nil {
		return err
	}
	var checkpoint time.Time
	if value == "" {
		checkpoint, err = store.Latest(id)
		if err != nil {
			return err
		}
		stamp := int64(0)
		if !checkpoint.IsZero() {
			stamp = checkpoint.UnixMicro()
		}
		if err = store.SetMeta(key, strconv.FormatInt(stamp, 10)); err != nil {
			return err
		}
	} else {
		stamp, parseErr := strconv.ParseInt(value, 10, 64)
		if parseErr != nil {
			return fmt.Errorf("invalid live checkpoint")
		}
		if stamp != 0 {
			checkpoint = time.UnixMicro(stamp)
		}
	}
	boundary := since
	if !checkpoint.IsZero() && checkpoint.Add(-24*time.Hour).After(boundary) {
		boundary = checkpoint.Add(-24 * time.Hour)
	}
	if !changedAt.IsZero() && changedAt.Before(boundary) && !changedAt.Before(since) {
		boundary = changedAt
	}
	if maxPages < 1 || since.IsZero() {
		return fmt.Errorf("invalid catch-up limits")
	}
	var cursor json.RawMessage
	seen := map[string]bool{}
	newest := checkpoint
	finish := func() error {
		stamp := int64(0)
		if !newest.IsZero() {
			stamp = newest.UnixMicro()
		}
		return store.SetMeta(key, strconv.FormatInt(stamp, 10))
	}
	for n := 0; n < maxPages; n++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		if seen[string(cursor)] {
			return fmt.Errorf("catch-up cursor repeated")
		}
		seen[string(cursor)] = true
		page, err := source.Fetch(ctx, id, cursor)
		if err != nil {
			return err
		}
		if len(page.Messages) == 0 {
			if len(page.Cursor) != 0 {
				return fmt.Errorf("empty catch-up page has continuation")
			}
			return finish()
		}
		keep := []archive.Message{}
		reached := false
		for i, m := range page.Messages {
			if m.ID == "" || m.ConversationID != id || m.Timestamp.Year() < 2000 || m.Timestamp.After(time.Now().Add(24*time.Hour)) {
				return fmt.Errorf("invalid catch-up message")
			}
			if i > 0 && m.Timestamp.After(page.Messages[i-1].Timestamp) {
				return fmt.Errorf("unordered catch-up page")
			}
			if m.Timestamp.After(newest) {
				newest = m.Timestamp
			}
			if m.Timestamp.Before(boundary) {
				reached = true
			} else {
				keep = append(keep, m)
			}
		}
		if err = store.PutUpdates(keep); err != nil {
			return err
		}
		if reached || len(page.Cursor) == 0 {
			return finish()
		}
		cursor = page.Cursor
	}
	return fmt.Errorf("catch-up page limit reached")
}
