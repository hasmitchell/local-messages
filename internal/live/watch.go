package live

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"io"
	"sync"
	"sync/atomic"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/google"
)

type Options struct {
	Commands                    <-chan archive.SendCommand
	Since                       time.Time
	MaxPages, ConversationLimit int
	// Presence is set by the app: true while it is in front. Nil means active.
	Presence      *atomic.Bool
	Media         string
	MediaBudget   int64
	RetentionDays int
}

// Status is the complete IPC contract. Never add message content, account names,
// IDs, upstream errors, credentials or filesystem paths to this stream.
type Status struct {
	Connection string `json:"connection,omitempty"`
	State      string `json:"state"`
	Time       string `json:"time"`
}

// TypingStatus is the one other line the worker prints. The conversation is
// identified by a digest so the stream still carries no raw identifiers.
type TypingStatus struct {
	Typing TypingInfo `json:"typing"`
	Time   string     `json:"time"`
}
type TypingInfo struct {
	Conversation string `json:"conversation"`
	Active       bool   `json:"active"`
}

func conversationDigest(id string) string {
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:8])
}

func Watch(ctx context.Context, store *archive.Store, opts Options, output io.Writer) error {
	return watch(ctx, store, opts, output, func(ctx context.Context, dir string, observer func(any)) (source, error) {
		return google.Connect(ctx, store, observer)
	})
}

func watch(ctx context.Context, store *archive.Store, opts Options, output io.Writer, connect connector) error {
	if opts.RetentionDays == 0 {
		if err := store.SetMeta("active_retention_floor", ""); err != nil {
			return err
		}
	}
	if err := store.CollectMedia(); err != nil {
		return err
	}
	if err := store.RecoverInterruptedSends(); err != nil {
		return err
	}
	presence := &atomic.Bool{}
	presence.Store(true)
	opts.Presence = presence
	router := &commandRouter{store: store, presence: presence}
	commandCtx, stopCommands := context.WithCancel(ctx)
	commandDone := make(chan struct{})
	go func() { defer close(commandDone); router.run(commandCtx, opts.Commands) }()
	defer func() { stopCommands(); <-commandDone }()
	encoder := json.NewEncoder(output)
	var outputMu sync.Mutex
	var last Status
	// Each sync pass reports its state. Only changes are written: every line
	// wakes the app, and an unchanged status would only cost it a redraw.
	emit := func(state string) {
		outputMu.Lock()
		defer outputMu.Unlock()
		status := Status{State: state, Time: time.Now().UTC().Format(time.RFC3339), Connection: router.token()}
		if status.State == last.State && status.Connection == last.Connection {
			return
		}
		last = status
		_ = encoder.Encode(status)
	}
	typing := func(conversationID string, active bool) {
		outputMu.Lock()
		defer outputMu.Unlock()
		_ = encoder.Encode(TypingStatus{Typing: TypingInfo{Conversation: conversationDigest(conversationID), Active: active}, Time: time.Now().UTC().Format(time.RFC3339)})
	}
	retry := 2 * time.Second
	for ctx.Err() == nil {
		child, cancel := context.WithCancel(ctx)
		buffer := &eventBuffer{cancel: cancel, wake: make(chan struct{}, 1), onTyping: typing}
		emit("connecting")
		client, err := connect(child, store.Dir, buffer.observe)
		if err == nil {
			if sending, ok := client.(sender); ok {
				router.set(&sendSession{token: uuid.NewString(), ctx: child, client: sending, refresh: func(id string) { buffer.request(id, time.Time{}) }})
			}
			started := time.Now()
			err = runSession(child, store, client, buffer, opts, emit)
			router.set(nil)
			cancel()
			client.Close()
			saveCtx, saveCancel := context.WithTimeout(context.Background(), 3*time.Second)
			if saveErr := client.Save(saveCtx); saveErr != nil && ctx.Err() == nil {
				emit("keychain_error")
			}
			saveCancel()
			if time.Since(started) > 2*time.Minute {
				retry = 2 * time.Second
			}
		}
		cancel()
		failure := buffer.failureState()
		if ctx.Err() != nil {
			break
		}
		if failure == "pairing_required" || errors.Is(err, google.ErrPairingUnavailable) || errors.Is(err, google.ErrOriginalIdentityMissing) || errors.Is(err, archive.ErrIdentityMismatch) {
			emit("pairing_required")
			return nil
		}
		if failure == "catchup_incomplete" {
			emit("catchup_incomplete")
		} else {
			emit("reconnecting")
		}
		select {
		case <-ctx.Done():
		case <-time.After(retry):
		}
		if retry < time.Minute {
			retry *= 2
		}
		if retry > time.Minute {
			retry = time.Minute
		}
	}
	emit("stopped")
	return nil
}

func runSession(ctx context.Context, store *archive.Store, client source, buffer *eventBuffer, opts Options, emit func(string)) error {
	work := &conversationWork{}
	priorityCtx, stopPriority := context.WithCancel(ctx)
	priorityDone := make(chan struct{})
	go func(priorityOptions Options) {
		defer close(priorityDone)
		runPriority(priorityCtx, store, client, buffer, work, priorityOptions)
	}(opts)
	defer func() { stopPriority(); <-priorityDone }()
	// The event buffer is installed before Connect; updates received during
	// initial catch-up and media downloads remain queued for the next pass.
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	nextInventory := time.Time{}
	nextCleanup := time.Time{}
	photosIncomplete := false
	credentialProblem := false
	nextMedia := time.Time{}
	mediaDone := make(chan error, 1)
	mediaRunning := false
	// The session outlives its photo goroutine. Cancel then join before closing
	// the client/store, including on sleep, logout and transient failures.
	mediaContext, stopMedia := context.WithCancel(ctx)
	defer func() {
		stopMedia()
		if mediaRunning {
			<-mediaDone
		}
	}()
	retryDirty := map[string]time.Time{}
	known := map[string]bool{}
	lastSweep := map[string]time.Time{}
	nextBackfill := time.Time{}
	active := func() bool { return opts.Presence == nil || opts.Presence.Load() }
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		// Every request here is served by the phone, so the cadence follows
		// whether anyone is looking: fresh messages still arrive through events.
		inventoryInterval, sweepInterval, mediaInterval, backfillPace := 5*time.Minute, 30*time.Minute, 5*time.Minute, 2*time.Second
		if !active() {
			inventoryInterval, sweepInterval, mediaInterval, backfillPace = 15*time.Minute, 2*time.Hour, 15*time.Minute, 10*time.Second
		}
		opts.Since = (archive.Settings{RetentionDays: opts.RetentionDays}).Cutoff(opts.Since, time.Now().UTC())
		if opts.RetentionDays > 0 && !mediaRunning && time.Now().After(nextCleanup) {
			if err := store.PruneBefore(archive.Settings{RetentionDays: opts.RetentionDays}.Cutoff(time.Time{}, time.Now().UTC())); err != nil {
				return err
			}
			nextCleanup = time.Now().Add(24 * time.Hour)
		}
		p := buffer.take()
		for _, echo := range p.echoes {
			if err := store.ConfirmSend(echo.clientID, echo.conversationID, echo.messageID); err != nil {
				return err
			}
		}
		for id, update := range p.unread {
			if err := store.UpdateUnread(id, update.unread, update.lastMessage); err != nil {
				return err
			}
		}
		if p.save {
			saveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err := client.Save(saveCtx)
			cancel()
			credentialProblem = err != nil
		}
		if len(p.echoes) > 0 || p.save {
			// A sent photo shows at once from the staged upload, without
			// waiting for the next media pass.
			if _, err := store.AdoptSentOriginals(); err != nil {
				return err
			}
		}
		for id, at := range p.dirty {
			previous, exists := retryDirty[id]
			if !exists || (!at.IsZero() && (previous.IsZero() || at.Before(previous))) {
				retryDirty[id] = at
			}
		}
		incomplete := false
		if time.Now().After(nextInventory) || (p.inventory && time.Until(nextInventory) < 90*time.Second) {
			emit("catching_up")
			for _, folder := range []gmproto.ListConversationsRequest_Folder{gmproto.ListConversationsRequest_INBOX, gmproto.ListConversationsRequest_ARCHIVE} {
				if folder == gmproto.ListConversationsRequest_INBOX {
					emit("checking_inbox")
				} else {
					emit("checking_archive")
				}
				conversations, err := client.Conversations(ctx, folder, opts.ConversationLimit)
				if err != nil {
					return err
				}
				for _, conv := range conversations {
					latest, err := store.Latest(conv.ID)
					if err != nil {
						return err
					}
					if err = store.PutConversation(conv); err != nil {
						return err
					}
					// Refresh threads with new activity or missing history at once;
					// recently active threads are swept on a slower cadence so
					// receipts and reactions that carry no event still arrive.
					needsHistory, err := needsHistory(store, conv.ID, opts.Since)
					if err != nil {
						return err
					}
					recent := conv.LastMessage.After(time.Now().Add(-7*24*time.Hour)) && time.Since(lastSweep[conv.ID]) > sweepInterval
					if !conv.LastMessage.Before(opts.Since) && (needsHistory || latest.IsZero() || conv.LastMessage.After(latest) || recent) {
						if _, exists := retryDirty[conv.ID]; !exists {
							retryDirty[conv.ID] = time.Time{}
						}
						lastSweep[conv.ID] = time.Now()
					}
					known[conv.ID] = true
				}
			}
			nextInventory = time.Now().Add(inventoryInterval)
			if err := refreshAvatars(ctx, store, client, avatarBatchLimit); err != nil {
				return err
			}
			if err := refreshContacts(ctx, store, client); err != nil {
				return err
			}
		}
		if len(retryDirty) > 0 {
			emit("catching_up")
		}
		for id, changedAt := range retryDirty {
			if !known[id] {
				conv, include, err := client.Lookup(ctx, id)
				if err != nil {
					return err
				}
				if !include {
					delete(retryDirty, id)
					continue
				}
				if err = store.PutConversation(conv); err != nil {
					return err
				}

				known[id] = true
			}
			if err := work.run(id, func() error {
				if err := CatchUp(ctx, store, client, id, opts.Since, changedAt, opts.MaxPages); err != nil {
					return err
				}
				// Older history is imported one page at a time at a bounded pace;
				// a deferred page keeps the thread queued for the next loop.
				if time.Now().Before(nextBackfill) {
					needed, err := needsHistory(store, id, opts.Since)
					if err != nil {
						return err
					}
					if needed {
						return errBackfillDeferred
					}
					return nil
				}
				nextBackfill = time.Now().Add(backfillPace)
				return backfillHistory(ctx, store, client, id, opts)
			}); err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, libgm.ErrPhoneNotResponding) || errors.Is(err, libgm.ErrConnectionClosed) {
					return err
				}
				incomplete = true
				continue
			}
			delete(retryDirty, id)
		}

		select {
		case mediaErr := <-mediaDone:
			mediaRunning = false
			nextMedia = time.Now().Add(mediaInterval)
			photosIncomplete = mediaErr != nil
			if err := store.CollectMedia(); err != nil {
				return err
			}
		default:
		}
		if !mediaRunning && time.Now().After(nextMedia) && opts.Media != "none" {
			mediaRunning = true
			mediaOptions := opts
			// Text sync stays responsive while originals are fetched.
			go func() {
				photoCtx, cancel := context.WithTimeout(mediaContext, 90*time.Second)
				defer cancel()
				mediaDone <- client.Download(photoCtx, store, mediaOptions.Since, mediaOptions.Media, mediaOptions.MediaBudget)
			}()
		}

		switch {
		case credentialProblem:
			emit("keychain_error")
		case incomplete:
			emit("catchup_incomplete")
		case photosIncomplete:
			emit("photos_pending")
		default:
			emit("connected")
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
		// Failed threads are retried at a bounded pace; live events still queue.
		if incomplete {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(15 * time.Second):
			}
		}
	}
}
