package live

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/history"
)

type slowInventory struct {
	fakeSource
	started chan struct{}
}

func (s *slowInventory) Conversations(ctx context.Context, _ gmproto.ListConversationsRequest_Folder, _ int) ([]archive.Conversation, error) {
	close(s.started)
	<-ctx.Done()
	return nil, ctx.Err()
}
func (s *slowInventory) Lookup(context.Context, string) (archive.Conversation, bool, error) {
	return archive.Conversation{ID: "live", Name: "Synthetic", LastMessage: time.Now()}, true, nil
}
func (s *slowInventory) Fetch(context.Context, string, json.RawMessage) (history.Page, error) {
	return history.Page{Messages: []archive.Message{{ID: "reply", ConversationID: "live", Timestamp: time.Now(), Body: "synthetic reply", Status: "INCOMING_COMPLETE"}}}, nil
}
func TestFreshReplyDoesNotWaitForInventory(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	buffer := &eventBuffer{cancel: cancel, wake: make(chan struct{}, 1)}
	source := &slowInventory{started: make(chan struct{})}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = runSession(ctx, store, source, buffer, Options{Since: time.Now().AddDate(-1, 0, 0), MaxPages: 100, Media: "none"}, func(string) {})
	}()
	<-source.started
	buffer.request("live", time.Now())
	for ctx.Err() == nil {
		if _, err := store.MessageByID("reply"); err == nil {
			cancel()
			<-done
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	<-done
	t.Fatal("fresh reply waited behind a blocked inventory request")
}

func TestEarlierHistoryRequestedAfterRetention(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	since := time.Now().UTC().AddDate(-1, 0, 0)
	if err := store.PutPage(nil, archive.Progress{ConversationID: "c", Since: since, State: "boundary_reached"}); err != nil {
		t.Fatal(err)
	}
	if needed, err := needsHistory(store, "c", since); err != nil || needed {
		t.Fatal("repeated complete original import")
	}
	floor := since.AddDate(0, 6, 0)
	store.SetMeta("retention_floor", floor.Format("2006-01-02"))
	if needed, err := needsHistory(store, "c", since); err != nil || !needed {
		t.Fatal("pruned history could not be fetched again")
	}
	store.SetMeta("history_coverage:c", since.Format("2006-01-02"))
	if needed, err := needsHistory(store, "c", since); err != nil || needed {
		t.Fatal("completed restored history repeated")
	}
}
