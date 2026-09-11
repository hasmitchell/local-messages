package live

import (
	"context"
	"fmt"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"sync"
	"testing"
	"time"
)

func TestEventsCoalesceWithoutReplayOverwrites(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b := &eventBuffer{cancel: cancel}
	now := time.Now().UnixMicro()
	var wg sync.WaitGroup
	for i := range 50 {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			b.observe(&libgm.WrappedMessage{Message: &gmproto.Message{ConversationID: "c", Timestamp: now - int64(i)}})
		}(i)
	}
	wg.Wait()
	b.observe(&libgm.WrappedMessage{Message: &gmproto.Message{ConversationID: "old", Timestamp: now}, IsOld: true})
	p := b.take()
	if len(p.dirty) != 1 || p.dirty["c"].UnixMicro() != now-49 {
		t.Fatal("events not coalesced to oldest change")
	}
	if ctx.Err() != nil {
		t.Fatal("ordinary update disconnected")
	}
	b.observe(&events.GaiaLoggedOut{})
	b.take() // Draining the queue cannot lose the terminal failure reason.
	if ctx.Err() == nil || b.failureState() != "pairing_required" {
		t.Fatal("lost logout")
	}
}
func TestOverflowForcesCatchUpInsteadOfSilentLoss(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b := &eventBuffer{cancel: cancel}
	for i := range 2049 {
		b.observe(&gmproto.Conversation{ConversationID: fmt.Sprint(i)})
	}
	if ctx.Err() == nil || b.failureState() != "catchup_incomplete" || len(b.take().dirty) != 2048 {
		t.Fatal("unbounded queue or silent loss")
	}
}
