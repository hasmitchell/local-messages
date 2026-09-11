package live

import (
	"strings"
	"sync"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

type sendEcho struct{ clientID, conversationID, messageID string }

type pendingEvents struct {
	echoes          []sendEcho
	dirty           map[string]time.Time
	inventory, save bool
}
type eventBuffer struct {
	failure  string
	mu       sync.Mutex
	pending  pendingEvents
	priority map[string]time.Time
	wake     chan struct{}
	cancel   func()
	// onTyping forwards the phone's typing notices to the app straight away.
	onTyping func(conversationID string, typing bool)
}

func (b *eventBuffer) observe(event any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	switch e := event.(type) {
	case *libgm.WrappedMessage:
		if e.GetTmpID() != "" && e.GetMessageID() != "" && strings.HasPrefix(e.GetMessageStatus().GetStatus().String(), "OUTGOING_") {
			if len(b.pending.echoes) >= 2048 {
				b.failure = "catchup_incomplete"
				b.cancel()
				return
			}
			b.pending.echoes = append(b.pending.echoes, sendEcho{e.GetTmpID(), e.GetConversationID(), e.GetMessageID()})
			b.mark(e.GetConversationID(), time.Time{})
		}
		// Replay is reconciled by catch-up. Treat fresh events as invalidations:
		// re-read current phone data so an old event cannot overwrite a new edit.
		if !e.IsOld {
			b.mark(e.GetConversationID(), time.UnixMicro(e.GetTimestamp()))
		}
	case *gmproto.TypingData:
		if b.onTyping != nil && e.GetConversationID() != "" {
			b.onTyping(e.GetConversationID(), e.GetType() == gmproto.TypingTypes_STARTED_TYPING)
		}
	case *gmproto.Conversation:
		b.pending.inventory = true
		b.mark(e.GetConversationID(), time.Time{})
	case *events.GaiaLoggedOut:
		b.failure = "pairing_required"
		b.cancel()
	case *events.ListenFatalError, *events.ListenTemporaryError, *events.NoDataReceived, *events.PhoneNotResponding:
		if b.failure == "" {
			b.failure = "reconnecting"
		}
		b.cancel()
	case *events.ListenRecovered, *events.PhoneRespondingAgain:
		b.pending.inventory = true
	case *events.AuthTokenRefreshed:
		b.pending.save = true
	}
}
func (b *eventBuffer) mark(id string, at time.Time) {
	if id == "" {
		return
	}
	if b.pending.dirty == nil {
		b.pending.dirty = map[string]time.Time{}
	}
	previous, exists := b.pending.dirty[id]
	if !exists && len(b.pending.dirty) >= 2048 {
		if b.failure == "" {
			b.failure = "catchup_incomplete"
		}
		b.cancel()
		return
	}
	if !exists || (!at.IsZero() && (previous.IsZero() || at.Before(previous))) {
		b.pending.dirty[id] = at
	}
	if b.priority == nil {
		b.priority = map[string]time.Time{}
	}
	previous, exists = b.priority[id]
	if !exists && len(b.priority) >= 2048 {
		b.failure = "catchup_incomplete"
		b.cancel()
		return
	}
	if !exists || (!at.IsZero() && (previous.IsZero() || at.Before(previous))) {
		b.priority[id] = at
	}
	select {
	case b.wake <- struct{}{}:
	default:
	}
}
func (b *eventBuffer) take() pendingEvents {
	b.mu.Lock()
	defer b.mu.Unlock()
	p := b.pending
	b.pending = pendingEvents{}
	return p
}

func (b *eventBuffer) failureState() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.failure
}
