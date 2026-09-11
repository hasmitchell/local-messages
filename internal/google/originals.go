package google

import (
	"context"
	"fmt"
	"strings"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"local/GoogleMessagingAppMac/internal/archive"
)

type mediaWaiter struct {
	updates chan archive.Attachment
}

type mediaReference struct{ message, action string }

const maxCachedMediaReferences = 4096

// Full-size requests return an empty acknowledgement. The actual download ID
// and key arrive later in the normal message-update stream.
func (c *Client) receiveMediaUpdate(event any) {
	wrapped, ok := event.(*libgm.WrappedMessage)
	if !ok || wrapped.Message == nil {
		return
	}
	c.mediaMu.Lock()
	defer c.mediaMu.Unlock()
	for _, a := range Convert(wrapped.Message).Attachments {
		if a.ActionID == "" || a.MediaID == "" || len(a.Key) == 0 {
			continue
		}
		key := mediaReference{wrapped.GetMessageID(), a.ActionID}
		if c.mediaCache == nil {
			c.mediaCache = make(map[mediaReference]archive.Attachment)
		}
		if _, exists := c.mediaCache[key]; !exists {
			if len(c.mediaCacheOrder) >= maxCachedMediaReferences {
				delete(c.mediaCache, c.mediaCacheOrder[0])
				c.mediaCacheOrder = c.mediaCacheOrder[1:]
			}
			c.mediaCacheOrder = append(c.mediaCacheOrder, key)
		}
		c.mediaCache[key] = a
		if waiter := c.mediaWaiters[key]; waiter != nil {
			select {
			case waiter.updates <- a:
			default:
			}
		}
	}
}

func (c *Client) resolveOriginal(ctx context.Context, messageID string, a *archive.Attachment) error {
	action := a.ActionID
	// Older probe records used the real action ID as their attachment ID. Only
	// use that when it isn't the explicitly synthetic messageID:index fallback.
	if action == "" && !strings.HasPrefix(a.ID, messageID+":") {
		action = a.ID
	}
	if action == "" {
		return fmt.Errorf("original has no action reference")
	}
	// The phone may need to upload an older attachment before publishing its
	// download reference. Allow the same minute as the upstream RPC deadline.
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	key := mediaReference{messageID, action}
	waiter := &mediaWaiter{updates: make(chan archive.Attachment, 1)}
	c.mediaMu.Lock()
	if cached, ok := c.mediaCache[key]; ok {
		c.mediaMu.Unlock()
		applyOriginal(a, cached)
		return nil
	}
	if c.mediaWaiters == nil {
		c.mediaWaiters = make(map[mediaReference]*mediaWaiter)
	}
	c.mediaWaiters[key] = waiter
	c.mediaMu.Unlock()
	defer func() { c.mediaMu.Lock(); delete(c.mediaWaiters, key); c.mediaMu.Unlock() }()
	updated, err := awaitOriginal(ctx, waiter.updates, func(requestCtx context.Context) error {
		_, err := c.GM.GetFullSizeImage(requestCtx, messageID, action)
		return err
	})
	if err != nil {
		return err
	}
	applyOriginal(a, updated)
	return nil
}

func awaitOriginal(ctx context.Context, updates <-chan archive.Attachment, request func(context.Context) error) (archive.Attachment, error) {
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	finished := make(chan error, 1)
	acknowledged := false
	go func() { finished <- request(child) }()
	for {
		select {
		case a := <-updates:
			return a, nil
		case err := <-finished:
			if err != nil {
				select {
				case a := <-updates:
					return a, nil
				default:
				}
				return archive.Attachment{}, &originalRequestError{stage: "request", cause: err}
			}
			acknowledged = true
			finished = nil
		case <-child.Done():
			stage := "request or update"
			if acknowledged {
				stage = "update after acknowledgement"
			}
			return archive.Attachment{}, &originalRequestError{stage: stage, cause: child.Err()}
		}
	}
}

type originalRequestError struct {
	stage string
	cause error
}

func (e *originalRequestError) Error() string {
	return fmt.Sprintf("full-size %s failed (%s)", e.stage, diagnostic(e.cause))
}
func (e *originalRequestError) Unwrap() error { return e.cause }
