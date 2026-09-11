package google

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

// A batch scans a bounded number of history pages; whatever it settles is
// persisted, so an interrupted batch never repeats the same work.
const refreshPageBudget = 30

// Refresh only attachment references on already archived messages. In particular,
// this must not change the text snapshot, history checkpoints or downloaded files.
func refreshMedia(ctx context.Context, store *archive.Store, source history.Source, messages []archive.Message, mode string, budget int64) (int, error) {
	groups := make(map[string]map[string]int)
	var order []string
	for i, m := range messages {
		for _, a := range m.Attachments {
			if !needsMediaReference(a, mode, budget) {
				continue
			}
			if groups[m.ConversationID] == nil {
				groups[m.ConversationID] = make(map[string]int)
				order = append(order, m.ConversationID)
			}
			groups[m.ConversationID][m.ID] = i
			break
		}
	}
	recovered := 0
	pages := 0
	for _, conversationID := range order {
		if pages >= refreshPageBudget {
			break
		}
		targets := groups[conversationID]
		var cursor json.RawMessage
		seen := make(map[string]bool)
		exhausted := false
		// Missing target IDs do not justify an unlimited scan. Unlike history
		// import, stopping this lookup makes no claim of complete coverage.
		for pageNumber := 0; pageNumber < 100 && len(targets) > 0 && pages < refreshPageBudget; pageNumber++ {
			if err := ctx.Err(); err != nil {
				return recovered, err
			}
			if seen[string(cursor)] {
				exhausted = true
				break
			}
			seen[string(cursor)] = true
			page, err := source.Fetch(ctx, conversationID, cursor)
			if err != nil {
				return recovered, fmt.Errorf("refreshing attachment references: %w", err)
			}
			pages++
			for _, fresh := range page.Messages {
				i, ok := targets[fresh.ID]
				if !ok || fresh.ConversationID != conversationID {
					continue
				}
				changed := mergeMediaReferences(&messages[i], fresh, mode, budget)
				// Finding the message without an original is a completed lookup:
				// the full-size request may still succeed, but not this batch's scan.
				for j := range messages[i].Attachments {
					a := &messages[i].Attachments[j]
					if needsMediaReference(*a, mode, budget) {
						a.RecordFailure(time.Now())
					}
				}
				if err := persist(store, messages[i]); err != nil {
					return recovered, err
				}
				recovered += changed
				delete(targets, fresh.ID)
			}
			if len(page.Messages) == 0 || len(page.Cursor) == 0 {
				exhausted = true
				break
			}
			cursor = page.Cursor
		}
		if exhausted {
			// History no longer contains these messages; retry on the backoff schedule.
			for _, i := range targets {
				for j := range messages[i].Attachments {
					a := &messages[i].Attachments[j]
					if needsMediaReference(*a, mode, budget) {
						a.RecordFailure(time.Now())
					}
				}
				if err := persist(store, messages[i]); err != nil {
					return recovered, err
				}
			}
		}
	}
	return recovered, nil
}

func persist(store *archive.Store, m archive.Message) error {
	if store == nil {
		return nil
	}
	return store.UpdateMedia(m)
}

func needsMediaReference(a archive.Attachment, mode string, budget int64) bool {
	return mode != "none" && budget > 0 && a.Size <= budget && a.Size <= 64<<20 &&
		a.State != "downloaded_original" && (a.MediaID == "" || len(a.Key) == 0) &&
		a.IncludedIn(mode) && a.Due(time.Now())
}

func mergeMediaReferences(saved *archive.Message, fresh archive.Message, mode string, budget int64) int {
	changed := 0
	for i := range saved.Attachments {
		a := &saved.Attachments[i]
		if !needsMediaReference(*a, mode, budget) {
			continue
		}
		for _, update := range fresh.Attachments {
			if a.ID == update.ID && update.MediaID != "" && len(update.Key) > 0 {
				applyOriginal(a, update)
				changed++
				break
			}
		}
	}
	return changed
}

func applyOriginal(a *archive.Attachment, update archive.Attachment) {
	a.MediaID = update.MediaID
	a.Key = update.Key
	if update.ActionID != "" {
		a.ActionID = update.ActionID
	}
	if update.Size > 0 {
		a.Size = update.Size
	}
	if update.MIME != "" {
		a.MIME = update.MIME
	}
	a.State = "pending"
}
