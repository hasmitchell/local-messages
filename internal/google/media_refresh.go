package google

import (
	"context"
	"encoding/json"
	"fmt"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

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
	for _, conversationID := range order {
		targets := groups[conversationID]
		var cursor json.RawMessage
		seen := make(map[string]bool)
		// Missing target IDs do not justify an unlimited scan. Unlike history
		// import, stopping this lookup makes no claim of complete coverage.
		for pageNumber := 0; pageNumber < 100 && len(targets) > 0; pageNumber++ {
			if err := ctx.Err(); err != nil {
				return recovered, err
			}
			if seen[string(cursor)] {
				break
			}
			seen[string(cursor)] = true
			page, err := source.Fetch(ctx, conversationID, cursor)
			if err != nil {
				return recovered, fmt.Errorf("refreshing attachment references: %w", err)
			}
			for _, fresh := range page.Messages {
				i, ok := targets[fresh.ID]
				if !ok || fresh.ConversationID != conversationID {
					continue
				}
				changed := mergeMediaReferences(&messages[i], fresh, mode, budget)
				if changed > 0 {
					if err := store.UpdateMedia(messages[i]); err != nil {
						return recovered, err
					}
					recovered += changed
				}
				// Finding the message without an original is still a completed
				// metadata lookup; its full-size upload can be requested later.
				delete(targets, fresh.ID)
			}
			if len(page.Messages) == 0 || len(page.Cursor) == 0 {
				break
			}
			cursor = page.Cursor
		}
	}
	return recovered, nil
}

func needsMediaReference(a archive.Attachment, mode string, budget int64) bool {
	return mode != "none" && budget > 0 && a.Size <= budget && a.Size <= 64<<20 &&
		a.State != "downloaded_original" && (a.MediaID == "" || len(a.Key) == 0) &&
		a.IncludedIn(mode)
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
