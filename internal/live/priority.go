package live

import (
	"context"
	"sync"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
)

// One lock per conversation prevents a slow historical snapshot from replacing
// a newer live fetch. Other conversations and inventory cannot block live work.
type conversationWork struct{ locks sync.Map }

func (w *conversationWork) run(id string, fn func() error) error {
	value, _ := w.locks.LoadOrStore(id, &sync.Mutex{})
	lock := value.(*sync.Mutex)
	lock.Lock()
	defer lock.Unlock()
	return fn()
}

func (b *eventBuffer) request(id string, at time.Time) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.mark(id, at)
}

func (b *eventBuffer) takePriority() map[string]time.Time {
	b.mu.Lock()
	defer b.mu.Unlock()
	result := b.priority
	b.priority = nil
	return result
}

func runPriority(ctx context.Context, store *archive.Store, client source, buffer *eventBuffer, work *conversationWork, opts Options) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for ctx.Err() == nil {
		opts.Since = (archive.Settings{RetentionDays: opts.RetentionDays}).Cutoff(opts.Since, time.Now().UTC())
		pending := buffer.takePriority()
		// A successful send response is not a delivery receipt. Re-read recent
		// attempts promptly even if Google omits/delays their live event.
		ids, _ := store.RecentSendConversations(time.Now().Add(-2 * time.Minute))
		for _, id := range ids {
			if pending == nil {
				pending = map[string]time.Time{}
			}
			if _, ok := pending[id]; !ok {
				pending[id] = time.Time{}
			}
		}
		for id, at := range pending {
			if ctx.Err() != nil {
				return
			}
			_ = work.run(id, func() error {
				conv, include, err := client.Lookup(ctx, id)
				if err != nil || !include {
					return err
				}
				if err = store.PutConversation(conv); err != nil {
					return err
				}
				// Bounded fast catch-up; the ordinary queue retains the complete
				// invalidation and handles any older pages or a transient failure.
				return CatchUp(ctx, store, client, id, opts.Since, at, 3)
			})
		}
		select {
		case <-ctx.Done():
			return
		case <-buffer.wake:
		case <-ticker.C:
		}
	}
}
