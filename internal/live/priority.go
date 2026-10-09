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

// prioritize hands a thread to the priority loop only; unlike request it adds
// no work to the main loop, which already has the thread queued.
func (b *eventBuffer) prioritize(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if id == "" {
		return
	}
	if b.priority == nil {
		b.priority = map[string]time.Time{}
	}
	if _, ok := b.priority[id]; !ok {
		if len(b.priority) >= 2048 {
			return
		}
		b.priority[id] = time.Time{}
	}
	select {
	case b.wake <- struct{}{}:
	default:
	}
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
				latest, err := store.Latest(id)
				if err != nil {
					return err
				}
				lookup := func() (bool, error) {
					conv, include, err := client.Lookup(ctx, id)
					if err != nil || !include {
						return false, err
					}
					return true, store.PutConversation(conv)
				}
				// An unknown thread is looked up first: the include filter (spam,
				// blocked, deleted) decides whether it is archived at all. A known
				// one fetches its messages first, so they reach the app a phone
				// round trip sooner.
				if latest.IsZero() {
					if included, err := lookup(); err != nil || !included {
						return err
					}
				}
				// Bounded fast catch-up; the ordinary queue retains the complete
				// invalidation and handles any older pages or a transient failure.
				if err = CatchUp(ctx, store, client, id, opts.Since, at, 3); err != nil {
					return err
				}
				// A sent photo's message has just been stored: keep the uploaded
				// file as its original now, so it never shows as "Not saved on this Mac".
				if _, err = store.AdoptRecentSentOriginals(time.Now().Add(-time.Hour)); err != nil {
					return err
				}
				if !latest.IsZero() {
					_, err = lookup()
					return err
				}
				return nil
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
