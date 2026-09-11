package history

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
)

type Page struct {
	Messages []archive.Message
	Cursor   json.RawMessage
}
type Source interface {
	Fetch(context.Context, string, json.RawMessage) (Page, error)
}
type Options struct {
	Since         time.Time
	MaxPages      int
	Resume        bool
	LatestMessage time.Time
}

// Import is a bounded history snapshot, not an always-on synchronisation engine.
// Resume continues that snapshot. A later fresh import refreshes newer content.
func Import(ctx context.Context, store *archive.Store, source Source, id string, opts Options) (archive.Progress, error) {
	p := archive.Progress{ConversationID: id, Since: opts.Since, State: "pending"}
	if opts.MaxPages < 1 || opts.Since.IsZero() {
		return p, fmt.Errorf("invalid history options")
	}
	// Conversation activity timestamps use the same units as messages. A known
	// latest message before the window means this thread has nothing to import.
	// Missing/invalid timestamps must still be fetched, never silently skipped.
	if opts.LatestMessage.Year() >= 2000 && opts.LatestMessage.Before(opts.Since) {
		p.State = "conversation_before_cutoff"
		return p, store.PutPage(nil, p)
	}
	if opts.Resume {
		old, err := store.Progress(id)
		if err != nil {
			return p, err
		}
		if old.ConversationID != "" {
			if !old.Since.Equal(opts.Since) {
				return p, fmt.Errorf("resume requires the same --since date as the original import")
			}
			p = old
			if p.State == "boundary_reached" || p.State == "source_exhausted" {
				return p, nil
			}
		}
	}
	finish := func(state string, cause error) (archive.Progress, error) {
		p.State = state
		if err := store.PutPage(nil, p); err != nil {
			return p, err
		}
		return p, cause
	}
	seen := map[string]bool{}
	for n := 0; n < opts.MaxPages; n++ {
		if ctx.Err() != nil {
			return finish("interrupted", ctx.Err())
		}
		cursorKey := string(p.Cursor)
		if seen[cursorKey] {
			return finish("stalled", fmt.Errorf("history cursor repeated"))
		}
		seen[cursorKey] = true
		page, err := source.Fetch(ctx, id, p.Cursor)
		if err != nil {
			state := "failed"
			if ctx.Err() != nil {
				state = "interrupted"
			}
			return finish(state, err)
		}
		if len(page.Messages) == 0 {
			// An empty page with a continuation token is not proof of exhaustion.
			if len(page.Cursor) > 0 {
				return finish("stalled", fmt.Errorf("empty history page still has a cursor"))
			}
			return finish("source_exhausted", nil)
		}
		keep := []archive.Message{}
		boundary := false
		for i, m := range page.Messages {
			if m.Timestamp.IsZero() || m.Timestamp.Year() < 2000 || m.Timestamp.After(time.Now().Add(24*time.Hour)) {
				return finish("invalid_timestamp", fmt.Errorf("history contains an unsupported timestamp"))
			}
			if i > 0 && m.Timestamp.After(page.Messages[i-1].Timestamp) {
				return finish("unordered_page", fmt.Errorf("history page was not newest-first; cannot infer cutoff coverage"))
			}
			if m.ConversationID != id {
				return finish("invalid_message", fmt.Errorf("history returned a different conversation"))
			}
			if p.Oldest == nil || m.Timestamp.Before(*p.Oldest) {
				t := m.Timestamp
				p.Oldest = &t
			}
			if m.Timestamp.Before(opts.Since) {
				boundary = true
				continue
			}
			keep = append(keep, m)
		}
		p.Pages++
		if boundary {
			p.State = "boundary_reached"
			p.Cursor = nil
		} else if len(page.Cursor) == 0 || string(page.Cursor) == cursorKey {
			p.State = "stalled"
		} else {
			p.State = "in_progress"
			p.Cursor = page.Cursor
		}
		if err = store.PutPage(keep, p); err != nil {
			return p, err
		}
		if boundary {
			return p, nil
		}
		if p.State == "stalled" {
			return p, fmt.Errorf("history did not provide an advancing cursor")
		}
	}
	return finish("page_limit", nil)
}
