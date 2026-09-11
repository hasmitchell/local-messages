package live

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"testing"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

type fetchFunc func(context.Context, string, json.RawMessage) (history.Page, error)

func (f fetchFunc) Fetch(ctx context.Context, id string, cursor json.RawMessage) (history.Page, error) {
	return f(ctx, id, cursor)
}
func TestInterruptedCatchUpDoesNotStrandGapOrReplaceHistoryCursor(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	baseline := time.Now().UTC().Truncate(time.Second).Add(-10 * 24 * time.Hour)
	message := func(id string, at time.Time) archive.Message {
		return archive.Message{ID: id, ConversationID: "c", Body: "booking", Timestamp: at}
	}
	initial := message("baseline", baseline)
	progress := archive.Progress{ConversationID: "c", State: "boundary_reached", Pages: 43, Cursor: json.RawMessage(`{"last":"historical"}`)}
	if err = store.PutPage([]archive.Message{initial}, progress); err != nil {
		t.Fatal(err)
	}
	calls := 0
	source := fetchFunc(func(ctx context.Context, id string, cursor json.RawMessage) (history.Page, error) {
		calls++
		if calls == 1 {
			return history.Page{Messages: []archive.Message{message("new", baseline.Add(9*24*time.Hour))}, Cursor: json.RawMessage(`"middle"`)}, nil
		}
		return history.Page{}, fmt.Errorf("interrupted")
	})
	since := baseline.Add(-365 * 24 * time.Hour)
	if err = CatchUp(context.Background(), store, source, "c", since, time.Time{}, 100); err == nil {
		t.Fatal("accepted interrupted catch-up")
	}
	checkpoint, _ := store.Meta("live_checkpoint:c")
	if checkpoint != strconv.FormatInt(baseline.UnixMicro(), 10) {
		t.Fatal("partial catch-up advanced checkpoint")
	}
	source = fetchFunc(func(ctx context.Context, id string, cursor json.RawMessage) (history.Page, error) {
		if len(cursor) == 0 {
			return history.Page{Messages: []archive.Message{message("new", baseline.Add(9*24*time.Hour))}, Cursor: json.RawMessage(`"middle"`)}, nil
		}
		return history.Page{Messages: []archive.Message{message("gap", baseline.Add(4*24*time.Hour)), initial, message("too-old", baseline.Add(-48*time.Hour))}}, nil
	})
	for range 2 {
		if err = CatchUp(context.Background(), store, source, "c", since, time.Time{}, 100); err != nil {
			t.Fatal(err)
		}
	}
	found, err := store.Search("booking", "", 10)
	if err != nil || len(found) != 3 {
		t.Fatal("gap lost, duplicate added or boundary exceeded", len(found), err)
	}
	after, _ := store.Progress("c")
	if after.State != progress.State || after.Pages != 43 || string(after.Cursor) != string(progress.Cursor) {
		t.Fatal("history progress changed")
	}
}
func TestCatchUpRejectsStallsAndMalformedPages(t *testing.T) {
	for _, mode := range []string{"limit", "repeat", "unordered", "wrong_thread", "bad_timestamp", "empty_cursor"} {
		t.Run(mode, func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			now := time.Now().UTC()
			source := fetchFunc(func(context.Context, string, json.RawMessage) (history.Page, error) {
				m := archive.Message{ID: "x", ConversationID: "c", Timestamp: now}
				p := history.Page{Messages: []archive.Message{m}, Cursor: json.RawMessage(`"next"`)}
				switch mode {
				case "unordered":
					p.Messages = append(p.Messages, archive.Message{ID: "y", ConversationID: "c", Timestamp: now.Add(time.Hour)})
				case "wrong_thread":
					p.Messages[0].ConversationID = "other"
				case "bad_timestamp":
					p.Messages[0].Timestamp = time.Time{}
				case "empty_cursor":
					p.Messages = nil
				}
				return p, nil
			})
			max := 5
			if mode == "limit" {
				max = 1
			}
			if err = CatchUp(context.Background(), store, source, "c", now.Add(-24*time.Hour), time.Time{}, max); err == nil {
				t.Fatal("accepted incomplete data")
			}
			checkpoint, _ := store.Meta("live_checkpoint:c")
			if checkpoint != "0" {
				t.Fatal("advanced checkpoint")
			}
		})
	}
}
func TestOldReactionEventExtendsRefreshBoundary(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now().UTC().Truncate(time.Second)
	recent := archive.Message{ID: "new", ConversationID: "c", Timestamp: now, Body: "recent"}
	old := archive.Message{ID: "old", ConversationID: "c", Timestamp: now.Add(-30 * 24 * time.Hour), Body: "older", Reactions: []archive.Reaction{{Emoji: "👍"}}}
	if err = store.PutUpdates([]archive.Message{recent}); err != nil {
		t.Fatal(err)
	}
	source := fetchFunc(func(context.Context, string, json.RawMessage) (history.Page, error) {
		return history.Page{Messages: []archive.Message{recent, old}}, nil
	})
	if err = CatchUp(context.Background(), store, source, "c", now.AddDate(-1, 0, 0), old.Timestamp, 100); err != nil {
		t.Fatal(err)
	}
	found, err := store.Search("older", "", 10)
	if err != nil || len(found) != 1 || len(found[0].Reactions) != 1 {
		t.Fatal("old reaction update was missed")
	}
}
